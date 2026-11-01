import ObjectiveC
import XCTest

/// Keep XCTest's run-loop synchronization, but use component assertions for visual readiness.
/// UIKit can leave a paused, offscreen image-menu animator active indefinitely. Waiting for
/// every animator therefore cannot establish whether the control under test is usable.
/// This adapter lives only in the UI runner; it never changes the app or its animations.
@MainActor
final class UIInteractionSynchronization {
    private typealias Wait = @convention(c) (NSObject, Selector, Bool, Bool) -> Void
    private let method: Method
    private let original: IMP
    private var replacement: IMP?

    init() throws {
        let selector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        let processClass = try XCTUnwrap(
            NSClassFromString("XCUIApplicationProcess"), "Xcode's UI synchronization class changed")
        method = try XCTUnwrap(
            class_getInstanceMethod(processClass, selector), "Xcode's UI synchronization method changed")
        let encoding = try XCTUnwrap(method_getTypeEncoding(method))
        guard String(cString: encoding) == "v24@0:8B16B20",
            class_getInstanceMethod(processClass, NSSelectorFromString("bundleID")) != nil
        else {
            throw NSError(
                domain: "UIInteractionSynchronization", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported XCTest ABI; review the UI runner adapter"])
        }
        original = method_getImplementation(method)
        let wait = unsafeBitCast(original, to: Wait.self)
        let block: @convention(block) (NSObject, Bool, Bool) -> Void = { process, animations, preEvent in
            let bundle = process.perform(NSSelectorFromString("bundleID"))?.takeUnretainedValue() as? String
            wait(process, selector, animations && bundle != "dev.catli.MarkdownIt", preEvent)
        }
        let implementation = imp_implementationWithBlock(block)
        replacement = implementation
        method_setImplementation(method, implementation)
    }

    func restore() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.replacement = nil
    }
}
