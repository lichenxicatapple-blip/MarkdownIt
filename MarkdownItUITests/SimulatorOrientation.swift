import Darwin
import ObjectiveC
import UIKit
import XCTest

/// Simulator-only device events. The app target never links this adapter.
/// Duo's legacy XCTest orientation setter changes its reported value without
/// rotating the scene. Use Device Hub's event and account for the inner panel.
/// Protocol reference: https://github.com/skarol/duoctl (MIT; see duoctl-LICENSE).
@MainActor
enum SimulatorOrientation {
    static func set(
        _ orientation: UIDeviceOrientation,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        #if targetEnvironment(simulator)
            do {
                guard let managerType = try hingeManagerType() else {
                    XCUIDevice.shared.orientation = orientation
                    return
                }
                let angle = try hingeAngle(managerType)
                let inner = angle > 0.5
                let value: String
                switch orientation {
                case .portrait: value = inner ? "landscape-left" : "portrait"
                case .portraitUpsideDown: value = inner ? "landscape-right" : "pud"
                case .landscapeLeft: value = inner ? "pud" : "landscape-left"
                case .landscapeRight: value = inner ? "portrait" : "landscape-right"
                default: throw failure("Unsupported Duo test orientation: \(orientation.rawValue)")
                }
                try XCTContext.runActivity(named: "Rotate hinge simulator (\(angle)°, \(value))") { _ in
                    try dispatch(value)
                }
            } catch {
                XCTFail("Simulator rotation failed: \(error)", file: file, line: line)
            }
        #else
            XCUIDevice.shared.orientation = orientation
        #endif
    }

    /// Read the target app's interface, independently of XCUIDevice's synthetic value.
    static func interfaceOrientation(of app: XCUIApplication) throws -> UIInterfaceOrientation {
        let selector = NSSelectorFromString("interfaceOrientation")
        guard app.responds(to: selector), let value = app.value(forKey: "interfaceOrientation") as? NSNumber,
            let orientation = UIInterfaceOrientation(rawValue: value.intValue)
        else { throw failure("Xcode's application interface-orientation API changed") }
        return orientation
    }

    static func interfaceOrientation(for device: UIDeviceOrientation) -> UIInterfaceOrientation {
        switch device {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: .unknown
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SimulatorOrientation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if targetEnvironment(simulator)
        private typealias Available = @convention(c) (AnyClass, Selector) -> Bool
        private typealias AngleHandler = @convention(block) @Sendable (NSObject) -> Void
        private typealias Start = @convention(c) (NSObject, Selector, OperationQueue, AngleHandler) -> Void
        private typealias Stop = @convention(c) (NSObject, Selector) -> Void
        private typealias Serialize = @convention(c) (CFTypeRef, CFOptionFlags) -> Unmanaged<CFData>?
        private typealias CreateEvent =
            @convention(c) (
                CFAllocator?, UInt64, UInt32, UInt32, UInt32, UnsafePointer<UInt8>?, CFIndex, UInt32
            ) -> Unmanaged<CFTypeRef>?
        private typealias CreateClient = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
        private typealias DispatchEvent = @convention(c) (CFTypeRef, CFTypeRef) -> Void

        private static let motion = dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW)
        private static let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        private static var eventClient: CFTypeRef?

        private static func hingeManagerType() throws -> NSObject.Type? {
            guard motion != nil, let type = NSClassFromString("CMAngleManager") as? NSObject.Type else { return nil }
            let selector = NSSelectorFromString("isAvailable")
            guard let method = class_getClassMethod(type, selector),
                let encoding = method_getTypeEncoding(method),
                ["B16@0:8", "c16@0:8"].contains(String(cString: encoding))
            else { throw failure("CoreMotion's hinge availability API changed") }
            let available = unsafeBitCast(method_getImplementation(method), to: Available.self)
            return available(type, selector) ? type : nil
        }

        private final class AngleReading: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Double?
            let ready = XCTestExpectation(description: "Receive the simulator's current hinge angle")

            func receive(_ reading: NSObject) {
                guard reading.responds(to: NSSelectorFromString("isAngleValid")),
                    reading.responds(to: NSSelectorFromString("angleDegrees")),
                    (reading.value(forKey: "isAngleValid") as? NSNumber)?.boolValue == true,
                    let angle = (reading.value(forKey: "angleDegrees") as? NSNumber)?.doubleValue, angle.isFinite
                else { return }
                lock.lock()
                defer { lock.unlock() }
                guard stored == nil else { return }
                stored = angle
                ready.fulfill()
            }

            var value: Double? {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
        }

        private static func hingeAngle(_ type: NSObject.Type) throws -> Double {
            let startSelector = NSSelectorFromString("startAngleUpdatesToQueue:handler:")
            let stopSelector = NSSelectorFromString("stopAngleUpdates")
            guard let startMethod = class_getInstanceMethod(type, startSelector),
                let stopMethod = class_getInstanceMethod(type, stopSelector),
                let startEncoding = method_getTypeEncoding(startMethod),
                let stopEncoding = method_getTypeEncoding(stopMethod),
                String(cString: startEncoding) == "v32@0:8@16@?24",
                String(cString: stopEncoding) == "v16@0:8"
            else { throw failure("CoreMotion's hinge update API changed") }
            let start = unsafeBitCast(method_getImplementation(startMethod), to: Start.self)
            let stop = unsafeBitCast(method_getImplementation(stopMethod), to: Stop.self)
            let manager = type.init()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let reading = AngleReading()
            let handler: AngleHandler = { reading.receive($0) }
            start(manager, startSelector, queue, handler)
            defer { stop(manager, stopSelector) }
            guard XCTWaiter.wait(for: [reading.ready], timeout: 5) == .completed, let angle = reading.value else {
                throw failure("The Duo simulator did not provide a hinge angle")
            }
            return angle
        }

        private static func symbol<Function>(_ name: String, as type: Function.Type) throws -> Function {
            guard let ioKit, let address = dlsym(ioKit, name) else {
                throw failure("The simulator's IOKit API is unavailable: \(name)")
            }
            return unsafeBitCast(address, to: type)
        }

        private static func dispatch(_ value: String) throws {
            let serialize = try symbol("IOCFSerialize", as: Serialize.self)
            let createEvent = try symbol("IOHIDEventCreateVendorDefinedEvent", as: CreateEvent.self)
            let dispatchEvent = try symbol("IOHIDEventSystemClientDispatchEvent", as: DispatchEvent.self)
            if eventClient == nil {
                let createClient = try symbol("IOHIDEventSystemClientCreateWithType", as: CreateClient.self)
                eventClient = createClient(nil, 4, nil)?.takeRetainedValue()
            }
            // Dispatch is asynchronous. Keep the client's connection alive until
            // the scene acknowledges rotation, including while the keyboard lays out.
            guard let client = eventClient else { throw failure("Cannot create the simulator's event client") }
            let payload: CFDictionary =
                [
                    "provider": "com.apple.Virtualization.VirtualMachines",
                    "source": "orientation-picker-control", "type": "enum", "value": value,
                ] as CFDictionary
            // The receiver requires IOCF serialization, rather than a binary plist.
            guard let data = serialize(payload, 1)?.takeRetainedValue(),
                let event = createEvent(
                    nil, mach_absolute_time(), 0xff61, 0x5b, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0
                )?.takeRetainedValue()
            else { throw failure("Cannot construct the simulator's orientation event") }
            dispatchEvent(client, event)
        }
    #endif
}
