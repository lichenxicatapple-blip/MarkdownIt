import ImageIO
import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

private final class SchemeRequest: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var data = Data()
    var response: URLResponse?
    var finished = false
    var error: Error?
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

final class ResourceHandlerTests: XCTestCase {
    func testPermissionPathShowsRealFoldersWithoutSandboxContainerIdentifiers() {
        let identifier = "11111111-2222-3333-4444-555555555555"
        let storage = "/private/var/mobile/Containers/Shared/AppGroup/\(identifier)/File Provider Storage"
        let provider = URL(fileURLWithPath: storage + "/Example Drive/Notes/阅读记录/images")
        XCTAssertEqual(ResourceFolderPath.display(provider), "Example Drive / Notes / 阅读记录 / images")
        let cloud = URL(fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Downloads/images")
        XCTAssertEqual(ResourceFolderPath.display(cloud), String(localized: "iCloud Drive") + " / Downloads / images")
        let local = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(identifier)/Documents/Notes/images")
        XCTAssertEqual(ResourceFolderPath.display(local), "Notes / images")
        let ordinary = URL(fileURLWithPath: "/Projects/File Provider Storage/images")
        XCTAssertEqual(ResourceFolderPath.display(ordinary), "Projects / File Provider Storage / images")
    }

    @MainActor
    func testWrongFolderGrantRepeatsThePermissionPromptAndCanBeCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let unrelated = root.appendingPathComponent("MarkdownIt", isDirectory: true)
        for folder in [downloads, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = downloads.appendingPathComponent("guide.md")
        let image = Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)
        try Data("# Images\n\n![Figure](figure.svg)\n".utf8).write(to: file)
        try image.write(to: downloads.appendingPathComponent("figure.svg"))
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        addTeardownBlock { @MainActor in
            await session.closeDocument()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        await session.open(file)
        let token = session.documentToken
        session.localResourcesChanged(["figure.svg"], token: token)
        let web = WKWebView()
        let url = try XCTUnwrap(URL(string: "jm-resource://\(token)/image?path=figure.svg"))
        let first = SchemeRequest(url)
        session.resources.webView(web, start: first)
        XCTAssertEqual((first.error as? CocoaError)?.code, .fileReadNoPermission)
        XCTAssertTrue(session.needsResourcePermission)
        XCTAssertEqual(session.resourcePermissionDirectory?.lastPathComponent, "Downloads")
        session.needsResourcePermission = false  // Dismiss the prompt before presenting the folder picker.
        let accepted = await session.grant(unrelated)
        XCTAssertFalse(accepted)
        XCTAssertTrue(session.needsResourcePermission)
        XCTAssertEqual(session.resourcePermissionDirectory?.lastPathComponent, "Downloads")
        XCTAssertFalse(session.recentDocuments.documents.flatMap(\.folders).contains { $0.url == unrelated })
        session.needsResourcePermission = false  // Cancel the repeated permission prompt.
        let second = SchemeRequest(url)
        session.resources.webView(web, start: second)
        XCTAssertEqual((second.error as? CocoaError)?.code, .fileReadNoPermission)
        XCTAssertFalse(
            session.needsResourcePermission, "Cancel returns to reading without immediately reopening the prompt")
        let valid = await session.grant(downloads)
        XCTAssertTrue(valid)
        XCTAssertNil(session.resourcePermissionDirectory)
        let third = SchemeRequest(url)
        session.resources.webView(web, start: third)
        let deadline = Date().addingTimeInterval(5)
        while !third.finished && third.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(third.finished)
        XCTAssertEqual(third.data, image)
        XCTAssertFalse(session.needsResourcePermission)
    }

    @MainActor
    func testWrongFolderSelectionReusesTheOriginalPermissionPrompt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("guide.md")
        try Data("# Images\n\n![Figure](images/figure.svg)\n".utf8).write(to: file)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let session = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await session.open(file)
        session.localResourcesChanged(["images/figure.svg"], token: session.documentToken)
        session.resources.onPermissionDenied?(session.documentToken, "images/figure.svg")
        session.needsResourcePermission = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Color.clear.modifier(ResourceFolderPermission(session: session)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            session.needsResourcePermission = false
            host.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKey()
            await session.closeDocument()
            defaults.removePersistentDomain(forName: defaultsName)
            try FileManager.default.removeItem(at: root)
        }
        let unrelated = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let accepted = await session.grant(unrelated)
        XCTAssertFalse(accepted)
        let deadline = Date().addingTimeInterval(5)
        while host.presentedViewController == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let original = try XCTUnwrap(host.presentedViewController)
        XCTAssertTrue(session.needsResourcePermission)
        XCTAssertFalse(original is UIAlertController, "The permission sheet supports a separately styled path")
        XCTAssertTrue(
            ResourceFolderPath.display(try XCTUnwrap(session.resourcePermissionDirectory)).hasSuffix(" / images"))
        let presentationDeadline = Date().addingTimeInterval(5)
        while original.isBeingPresented && Date() < presentationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(original.isBeingPresented)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "folder-permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        session.needsResourcePermission = false
        let dismissDeadline = Date().addingTimeInterval(5)
        while host.presentedViewController != nil && Date() < dismissDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host.presentedViewController)
    }

    @MainActor
    func testRecentDocumentRestoresGrantedImageFolderInANewSession() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for folder in [notes, assets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = notes.appendingPathComponent("readme.md")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"/>".utf8)
        try Data("# Images\n\n![Figure](../assets/figure.svg)\n".utf8).write(to: file)
        try svg.write(to: assets.appendingPathComponent("figure.svg"))
        var first: ReaderSession? = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await first?.open(file)
        await first?.grant(root)
        await first?.closeDocument()
        first = nil
        let restored = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        let record = try XCTUnwrap(restored.recentDocuments.documents.first)
        let opened = try await restored.openRecent(record)
        XCTAssertTrue(opened)
        var components = URLComponents()
        components.scheme = "jm-resource"
        components.host = restored.documentToken
        components.path = "/image"
        components.queryItems = [URLQueryItem(name: "path", value: "../assets/figure.svg")]
        let request = SchemeRequest(try XCTUnwrap(components.url))
        restored.resources.webView(WKWebView(), start: request)
        let deadline = Date().addingTimeInterval(5)
        while !request.finished && request.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(request.finished)
        XCTAssertNil(request.error)
        XCTAssertEqual(request.data, svg)
        await restored.closeDocument()
    }

    @MainActor
    func testDirectOpenRestoresGrantedImageFolderInANewSession() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for folder in [notes, assets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = notes.appendingPathComponent("readme.md")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"/>".utf8)
        try Data("# Images\n\n![Figure](../assets/figure.svg)\n".utf8).write(to: file)
        try svg.write(to: assets.appendingPathComponent("figure.svg"))
        var first: ReaderSession? = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await first?.open(file)
        await first?.grant(root)
        await first?.closeDocument()
        first = nil
        let restored = ReaderSession(defaults: defaults, modelSettings: isolatedModelSettings())
        await restored.open(file)
        XCTAssertEqual(restored.document?.fileURL, file, "Keep the fresh URL received from the system")
        var components = URLComponents()
        components.scheme = "jm-resource"
        components.host = restored.documentToken
        components.path = "/image"
        components.queryItems = [URLQueryItem(name: "path", value: "../assets/figure.svg")]
        let request = SchemeRequest(try XCTUnwrap(components.url))
        restored.resources.webView(WKWebView(), start: request)
        let deadline = Date().addingTimeInterval(5)
        while !request.finished && request.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(request.finished)
        XCTAssertNil(request.error)
        XCTAssertEqual(request.data, svg)
        await restored.closeDocument()
    }

    @MainActor
    func testMissingImageInGrantedFolderDoesNotRequestPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let handler = LocalResourceHandler()
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "missing"))
        var prompts = 0
        handler.onPermissionDenied = { _, _ in prompts += 1 }
        let request = SchemeRequest(try XCTUnwrap(URL(string: "jm-resource://missing/image?path=absent.svg")))
        handler.webView(WKWebView(), start: request)
        let deadline = Date().addingTimeInterval(5)
        while request.error == nil && !request.finished && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual((request.error as? CocoaError)?.code, .fileReadNoSuchFile)
        XCTAssertEqual(prompts, 0, "A missing file cannot be fixed by asking for directory access")
        XCTAssertFalse(request.finished)
    }

    func testPrivacyManifestIsIncludedInTheAppBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        let declarations = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = try XCTUnwrap(
            declarations.first {
                $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
            })
        XCTAssertEqual(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    @MainActor
    func testResourceResponseAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        try content.write(to: root.appendingPathComponent("figure.svg"))
        let handler = LocalResourceHandler()
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "test"))
        let webView = WKWebView()
        let url = try XCTUnwrap(URL(string: "jm-resource://test/image?path=figure.svg"))
        let request = SchemeRequest(url)
        handler.webView(webView, start: request)
        let deadline = Date().addingTimeInterval(3)
        while !request.finished && request.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(request.finished)
        XCTAssertNil(request.error)
        XCTAssertEqual(request.data, content)
        XCTAssertEqual(request.response?.mimeType, "image/svg+xml")
        let canceled = SchemeRequest(url)
        handler.webView(webView, start: canceled)
        handler.webView(webView, stop: canceled)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(canceled.finished)
        XCTAssertNil(canceled.response)
        XCTAssertTrue(canceled.data.isEmpty)
        XCTAssertNil(canceled.error, "WebKit forbids every callback after cancellation")
        let stale = SchemeRequest(try XCTUnwrap(URL(string: "jm-resource://another-document/image?path=figure.svg")))
        handler.webView(webView, start: stale)
        XCTAssertNotNil(stale.error)
        XCTAssertTrue(stale.data.isEmpty)
        var permissionPrompts = 0
        handler.onPermissionDenied = { token, source in
            XCTAssertEqual(token, "test")
            XCTAssertEqual(source, "figure.svg")
            permissionPrompts += 1
        }
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [], token: "test"))
        handler.webView(webView, start: SchemeRequest(url))
        handler.webView(webView, start: SchemeRequest(url))
        XCTAssertEqual(permissionPrompts, 1)
        handler.configure(
            ResourceAccess(documentURL: root.appendingPathComponent("guide.md"), roots: [root], token: "test"))
        let missing = SchemeRequest(try XCTUnwrap(URL(string: "jm-resource://test/image?path=missing.svg")))
        handler.webView(webView, start: missing)
        let missingDeadline = Date().addingTimeInterval(3)
        while missing.error == nil && Date() < missingDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(missing.error)
        XCTAssertEqual(permissionPrompts, 1, "A missing file is not a folder-permission failure")
    }
    @MainActor
    func testImageInventoryIsLazyAndSentPixelsStayImmutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("figure.png")
        func png(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            }
        }
        let original = png(.red)
        try original.write(to: file)
        let image = AgentImageReference(id: UUID().uuidString, source: "figure.png", alt: "Figure")
        var document = AgentAttachment(
            text: "![Figure](figure.png)", markdown: "![Figure](figure.png)", mode: "preview", scope: "document",
            location: nil, start: nil, end: nil)
        document.images = [image]
        let snapshot = AgentSnapshot(
            question: "What is shown?", attachment: document,
            history: [.init(role: "user", markdown: "What is shown?", attachment: document, document: document)],
            document: document)
        let access = ResourceAccess(
            documentURL: root.appendingPathComponent("note.md"), roots: [root], token: "image-test")
        let images = AgentImages()
        let initial = try await images.prepare(snapshot, access: access)
        XCTAssertTrue(initial.isEmpty, "Document-wide entry must not read image pixels eagerly")
        let call = ModelToolCall(id: "call", name: "read_image", arguments: "{\"imageID\":\"\(image.id)\"}")
        let first = await images.execute(call, access: access)
        let frozen = try XCTUnwrap(first.images.first)
        XCTAssertEqual(frozen.mimeType, "image/png")
        XCTAssertEqual(UIImage(data: frozen.data)?.cgImage?.width, UIImage(data: original)?.cgImage?.width)
        XCTAssertEqual(UIImage(data: frozen.data)?.cgImage?.height, UIImage(data: original)?.cgImage?.height)
        try png(.blue).write(to: file)
        let repeated = await images.execute(call, access: access)
        XCTAssertEqual(repeated.images, [frozen], "A tool retry must reuse already-observed pixels")
        let continued = try await images.prepare(snapshot, access: access)
        XCTAssertEqual(continued, [frozen], "A later round must retain the original visual evidence")
        let request = SchemeRequest(URL(string: "jm-image://image-test/\(image.id)")!)
        images.webView(WKWebView(), start: request)
        XCTAssertTrue(request.finished)
        XCTAssertEqual(request.data, frozen.data, "The sent quote renders the exact model image snapshot")
        images.reset()
        let stale = await images.execute(call, access: access)
        XCTAssertTrue(stale.images.isEmpty)
        XCTAssertTrue(stale.output.contains("unknown_image"))
    }

    @MainActor
    func testImageToolCannotReadUnreferencedFilesOrEscapeGrantedFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("allowed")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = AgentImageReference(id: UUID().uuidString, source: "../private.png", alt: "")
        var document = AgentAttachment(
            text: "", markdown: "![](../private.png)", mode: "preview", scope: "document", location: nil, start: nil,
            end: nil)
        document.images = [image]
        let snapshot = AgentSnapshot(
            question: "Look", attachment: document,
            history: [.init(role: "user", markdown: "Look", attachment: document, document: document)],
            document: document)
        let access = ResourceAccess(
            documentURL: allowed.appendingPathComponent("note.md"), roots: [allowed], token: "restricted")
        let images = AgentImages()
        _ = try await images.prepare(snapshot, access: access)
        for arguments in [
            "{\"imageID\":\"\(UUID().uuidString)\"}", "{\"path\":\"../private.png\"}",
            "{\"imageID\":\"\(image.id)\",\"path\":\"private.png\"}",
        ] {
            let result = await images.execute(
                ModelToolCall(id: "bad", name: "read_image", arguments: arguments), access: access)
            XCTAssertTrue(result.images.isEmpty)
            XCTAssertTrue(result.output.contains("unknown_image"))
        }
        let denied = await images.execute(
            ModelToolCall(id: "denied", name: "read_image", arguments: "{\"imageID\":\"\(image.id)\"}"), access: access)
        XCTAssertTrue(denied.images.isEmpty)
        XCTAssertTrue(denied.output.contains("image_permission"))
    }

    @MainActor
    func testSelectedSVGIsRasterizedIntoActualPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let svg =
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"60\"><rect width=\"120\" height=\"60\" fill=\"red\"/></svg>"
        try Data(svg.utf8).write(to: root.appendingPathComponent("picture.svg"))
        let reference = AgentImageReference(id: UUID().uuidString, source: "picture.svg", alt: "")
        var selected = AgentAttachment(
            text: "Image", markdown: "![](picture.svg)", mode: "preview", scope: nil, location: nil, start: nil,
            end: nil)
        selected.images = [reference]
        let snapshot = AgentSnapshot(
            question: "Look", attachment: selected,
            history: [.init(role: "user", markdown: "Look", attachment: selected)])
        let images = try await AgentImages().prepare(
            snapshot,
            access: ResourceAccess(documentURL: root.appendingPathComponent("note.md"), roots: [root], token: "svg"))
        let decoded = try XCTUnwrap(UIImage(data: XCTUnwrap(images.first).data)?.cgImage)
        XCTAssertEqual(CGFloat(decoded.width) / CGFloat(decoded.height), 2, accuracy: 0.01)
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(rgba[0], 200, "SVG conversion must contain the red drawing, not a blank WebView")
        XCTAssertLessThan(rgba[1], 20)
        XCTAssertGreaterThan(rgba[3], 200)
    }

    @MainActor
    func testRemoteImagesAreLazyAndDoNotCarryModelCredentials() async throws {
        ImageDownloadProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageDownloadProtocol.self]
        let images = AgentImages(network: URLSession(configuration: configuration))
        let reference = AgentImageReference(
            id: UUID().uuidString, source: "https://image.example.test/picture.png", alt: "Remote")
        var document = AgentAttachment(
            text: "", markdown: "![Remote](https://image.example.test/picture.png)", mode: "preview", scope: "document",
            location: nil, start: nil, end: nil)
        document.images = [reference]
        let snapshot = AgentSnapshot(
            question: "Look", attachment: document,
            history: [.init(role: "user", markdown: "Look", attachment: document, document: document)],
            document: document)
        let access = ResourceAccess(documentURL: URL(fileURLWithPath: "/note.md"), roots: [], token: "remote")
        _ = try await images.prepare(snapshot, access: access)
        XCTAssertTrue(ImageDownloadProtocol.state.requests.isEmpty)
        let result = await images.execute(
            ModelToolCall(id: "download", name: "read_image", arguments: "{\"imageID\":\"\(reference.id)\"}"),
            access: access)
        XCTAssertEqual(result.images.count, 1)
        let requests = ImageDownloadProtocol.state.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests.first?.httpBody)
    }

    @MainActor
    func testImagePixelsExcludeSourceGPSAndEXIFMetadata() async throws {
        let image = try XCTUnwrap(
            UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
            }.cgImage)
        let sourceData = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(sourceData, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, image,
            [
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
                ],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private camera information"],
            ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try XCTUnwrap(CGImageSourceCreateWithData(sourceData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(
            (originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment]
                as? String, "private camera information")
        let reference = AgentImageReference(
            id: UUID().uuidString, source: "data:image/jpeg;base64," + (sourceData as Data).base64EncodedString(),
            alt: "")
        var attachment = AgentAttachment(
            text: "Image", markdown: "", mode: "preview", scope: nil, location: nil, start: nil, end: nil)
        attachment.images = [reference]
        let snapshot = AgentSnapshot(
            question: "Look", attachment: attachment,
            history: [.init(role: "user", markdown: "Look", attachment: attachment)])
        let prepared = try await AgentImages().prepare(
            snapshot,
            access: ResourceAccess(documentURL: URL(fileURLWithPath: "/note.md"), roots: [], token: "metadata"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(XCTUnwrap(prepared.first).data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        // ImageIO may generate dimension and color-space fields while encoding.
        // The original private metadata must not accompany the pixels.
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
    }

}

private final class ImageDownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func reset() { lock.withLock { values = [] } }
    func record(_ request: URLRequest) { lock.withLock { values.append(request) } }
    var requests: [URLRequest] { lock.withLock { values } }
}

private final class ImageDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let state = ImageDownloadState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "image.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.record(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!
        )
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
