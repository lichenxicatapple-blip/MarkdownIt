import ImageIO
import UIKit
import WebKit

struct AgentImageReference: Codable, Sendable, Equatable {
    let id: String
    let source: String
    let alt: String
}

enum AgentImageError: Error {
    case unavailable, unsupported, invalidReference
}

/// A document session owns image identities and frozen pixels. The model gets
/// IDs, never a filesystem or arbitrary-URL read tool.
@MainActor
final class AgentImages: NSObject, WKURLSchemeHandler {
    struct Recovery: Codable, Sendable {
        let references: [String: AgentImageReference]
        let pixels: [String: ModelImage]
        let token: String
    }

    func checkpoint() -> Recovery { Recovery(references: references, pixels: pixels, token: token) }

    func restore(_ value: Recovery, token currentToken: String? = nil) {
        reset()
        references = value.references
        pixels = value.pixels
        token = currentToken ?? value.token
    }

    func retain(_ ids: Set<String>) {
        generation = UUID()
        references = references.filter { ids.contains($0.key) }
        pixels = pixels.filter { ids.contains($0.key) }
    }

    private var references: [String: AgentImageReference] = [:]
    private var pixels: [String: ModelImage] = [:]
    private var generation = UUID()
    private var token = ""
    private let network: URLSession

    init(network: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 90
        self.network = network ?? URLSession(configuration: configuration)
        super.init()
    }

    nonisolated static let definition = ModelTool(
        name: "read_image", description: "读取提供的图片清单中的一张图片，返回实际画面。只接受清单中的 imageID。",
        parameters: """
            {"type":"object","properties":{"imageID":{"type":"string"}},"required":["imageID"],"additionalProperties":false}
            """)

    func reset() {
        generation = UUID()
        token = ""
        references.removeAll()
        pixels.removeAll()
    }

    func prepare(_ snapshot: AgentSnapshot, access: ResourceAccess) async throws -> [ModelImage] {
        if token != access.token {
            reset()
            token = access.token
        }
        let attachments =
            snapshot.history.flatMap { [$0.document, $0.attachment].compactMap { $0 } }
            + [snapshot.document, snapshot.attachment].compactMap { $0 }
        for reference in attachments.flatMap({ $0.images ?? [] }) {
            guard UUID(uuidString: reference.id) != nil, !reference.source.isEmpty,
                references[reference.id] == nil || references[reference.id] == reference
            else { throw AgentImageError.invalidReference }
            references[reference.id] = reference
        }
        // Only selections are eager. Document-wide entry registers the inventory
        // without opening files or downloading every picture.
        for attachment in attachments where attachment.scope != "document" {
            for reference in attachment.images ?? [] { _ = try await load(reference.id, access: access) }
        }
        let ids = Set(attachments.flatMap { $0.images ?? [] }.map(\.id))
        return pixels.values.filter { ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    func execute(_ call: ModelToolCall, access: ResourceAccess) async -> AgentToolExecution {
        do {
            let arguments = try ModelWireFormat.object(Data(call.arguments.utf8))
            guard Set(arguments.keys) == ["imageID"], let id = arguments["imageID"] as? String else {
                throw AgentImageError.invalidReference
            }
            let image = try await load(id, access: access)
            return AgentToolExecution(output: "{\"imageID\":\"\(id)\",\"status\":\"loaded\"}", images: [image])
        } catch {
            let reason: String
            switch error {
            case AgentImageError.invalidReference: reason = "unknown_image"
            case AgentImageError.unsupported: reason = "unsupported_image"
            case let value as CocoaError where value.code == .fileReadNoPermission: reason = "image_permission"
            default: reason = "image_unavailable"
            }
            return AgentToolExecution(output: "{\"error\":\"\(reason)\",\"message\":\"未取得图片画面。请根据实际错误说明，不能猜测。\"}")
        }
    }

    var loadedIDs: [String] { pixels.keys.sorted() }

    func hasImages(in snapshot: AgentSnapshot) -> Bool {
        snapshot.history.flatMap { [$0.document, $0.attachment].compactMap { $0 } }
            .contains { !($0.images ?? []).isEmpty }
    }

    private func load(_ id: String, access: ResourceAccess) async throws -> ModelImage {
        guard token == access.token, let reference = references[id] else { throw AgentImageError.invalidReference }
        if let existing = pixels[id] { return existing }
        let currentGeneration = generation
        let data: Data
        if let url = URL(string: reference.source), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            guard url.user == nil, url.password == nil else { throw AgentImageError.invalidReference }
            var request = URLRequest(url: url)
            request.setValue("MarkdownIt", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await network.data(for: request, delegate: ImageRequestPolicy.shared)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw AgentImageError.unavailable
            }
            data = body
        } else if reference.source.lowercased().hasPrefix("data:image/") {
            guard let comma = reference.source.firstIndex(of: ",") else { throw AgentImageError.unsupported }
            let header = reference.source[..<comma]
            let value = String(reference.source[reference.source.index(after: comma)...])
            if header.hasSuffix(";base64"), let decoded = Data(base64Encoded: value) {
                data = decoded
            } else if let decoded = value.removingPercentEncoding {
                data = Data(decoded.utf8)
            } else {
                throw AgentImageError.unsupported
            }
        } else {
            let file = try access.resolve(reference.source)
            data = try await Task.detached(priority: .userInitiated) {
                try LocalResourceHandler.readCoordinated(file, options: [])
            }
            .value
        }
        try Task.checkCancellation()
        let image: ModelImage
        if let bitmap = try await Task.detached(
            priority: .userInitiated,
            operation: {
                try Self.bitmap(id: id, data: data)
            }
        ).value {
            image = bitmap
        } else {
            do {
                image = ModelImage(id: id, data: try await SVGImageRasterizer.rasterize(data), mimeType: "image/png")
            } catch {
                try Task.checkCancellation()
                throw AgentImageError.unsupported
            }
        }
        guard currentGeneration == generation, token == access.token else { throw CancellationError() }
        pixels[id] = image
        return image
    }

    nonisolated private static func bitmap(id: String, data: Data) throws -> ModelImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                ] as CFDictionary)
        {
            // Re-encode pixels, preserving their dimensions and orientation but
            // excluding source EXIF, GPS and other image metadata.
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw AgentImageError.unsupported
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw AgentImageError.unsupported }
            return ModelImage(id: id, data: output as Data, mimeType: "image/png")

        }
        return nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == token,
            let image = pixels[url.lastPathComponent]
        else {
            task.didFailWithError(AgentImageError.unavailable)
            return
        }
        task.didReceive(
            URLResponse(
                url: url, mimeType: image.mimeType, expectedContentLength: image.data.count, textEncodingName: nil))
        task.didReceive(image.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Image downloads never use the model connection's credentials or cookies.
private final class ImageRequestPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ImageRequestPolicy()
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil
        else {
            completionHandler(nil)
            return
        }
        var clean = request
        clean.setValue(nil, forHTTPHeaderField: "Authorization")
        clean.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(clean)
    }
}

/// WebKit decodes SVG as an image in an isolated page. CSP blocks scripts and
/// external subresources; no document markup or credentials enter this view.
@MainActor
private final class SVGImageRasterizer: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private let webView: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    static func rasterize(_ data: Data) async throws -> Data {
        let renderer = SVGImageRasterizer()
        let html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'">
            <style>html,body{margin:0;background:transparent}img{display:block}</style>
            <img src="data:image/svg+xml;base64,\(data.base64EncodedString())">
            """
        try await withCheckedThrowingContinuation { continuation in
            renderer.continuation = continuation
            renderer.webView.loadHTMLString(html, baseURL: nil)
        }
        let size =
            try await renderer.webView.callAsyncJavaScript(
                "const image=document.querySelector('img'); await image.decode(); return [image.naturalWidth,image.naturalHeight];",
                arguments: [:], in: nil, contentWorld: .defaultClient) as? [Double]
        guard let size, size.count == 2, size[0] > 0, size[1] > 0 else { throw AgentImageError.unsupported }
        renderer.webView.frame.size = CGSize(width: size[0], height: size[1])
        let snapshot = try await renderer.webView.takeSnapshot(configuration: nil)
        guard let png = snapshot.pngData() else { throw AgentImageError.unsupported }
        try Task.checkCancellation()
        return png
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
