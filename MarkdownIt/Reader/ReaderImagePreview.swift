import SwiftUI
import WebKit

/// Original bytes, isolated from the document's navigation and AI image snapshots.
struct ReaderLinkedImage: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data
}

struct ReaderImagePresentation: ViewModifier {
    @ObservedObject var session: ReaderSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .allowsHitTesting(session.linkedImage == nil)
                .accessibilityElement(children: .contain)
                .accessibilityHidden(session.linkedImage != nil)
            if let image = session.linkedImage {
                ReaderImagePreview(image: image, dismiss: session.dismissLinkedImage) {
                    session.linkedImageFailed(id: image.id)
                }
                .id(image.id)
                .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: ReaderDesign.toolsDuration),
            value: session.linkedImage?.id)
    }
}

private struct ReaderImagePreview: View {
    let image: ReaderLinkedImage
    let dismiss: () -> Void
    let failed: () -> Void
    @State private var imageSize: CGSize?

    var body: some View {
        GeometryReader { geometry in
            let inset = ReaderDesign.floatingInset
            let available = CGSize(
                width: max(1, geometry.size.width - inset * 2),
                height: max(1, geometry.size.height - (ReaderDesign.hitTarget + inset) * 2))
            let fitted = Self.fit(imageSize ?? available, inside: available)
            ZStack {
                Color(uiColor: ReaderDesign.modalScrim)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
                ReaderImageCanvas(image: image, loaded: { imageSize = $0 }, failed: failed)
                    .frame(width: fitted.width, height: fitted.height)
                    .background(Color(uiColor: .systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: ReaderDesign.imagePreviewRadius))
                    .opacity(imageSize == nil ? 0 : 1)
                    .accessibilityHidden(imageSize == nil)
                    .overlay { if imageSize == nil { ProgressView().tint(.white) } }
                    .accessibilityLabel(Text(verbatim: image.name))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: dismiss) {
                    ReaderChromeIcon("xmark")
                }
                .modifier(ReaderGlassControl())
                .foregroundStyle(.secondary)
                .padding(inset)
                .accessibilityLabel("Close image")
                .accessibilityIdentifier("CloseLinkedImage")
                .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
    }

    private static func fit(_ size: CGSize, inside available: CGSize) -> CGSize {
        let scale = min(available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

/// A separate image-only WebKit surface preserves the formats supported by the reader,
/// including WebP, SVG and animated images. Its scroll view owns zooming and panning.
private struct ReaderImageCanvas: UIViewRepresentable {
    let image: ReaderLinkedImage
    let loaded: (CGSize) -> Void
    let failed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(image: image, loaded: loaded, failed: failed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "jm-image-preview")
        configuration.userContentController.add(context.coordinator, name: "imagePreview")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "LinkedImageWebView"
        guard let file = Bundle.main.url(forResource: "image-preview", withExtension: "html", subdirectory: "Web"),
            let html = try? String(contentsOf: file, encoding: .utf8)
        else {
            context.coordinator.failed()
            return view
        }
        view.loadHTMLString(html, baseURL: URL(string: "jm-image-preview://image/"))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "imagePreview")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
        let image: ReaderLinkedImage
        let loaded: (CGSize) -> Void
        let failed: () -> Void

        init(image: ReaderLinkedImage, loaded: @escaping (CGSize) -> Void, failed: @escaping () -> Void) {
            self.image = image
            self.loaded = loaded
            self.failed = failed
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url, url.absoluteString == "jm-image-preview://image/content" else {
                urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
                return
            }
            urlSchemeTask.didReceive(
                URLResponse(
                    url: url, mimeType: image.mimeType, expectedContentLength: image.data.count,
                    textEncodingName: nil))
            urlSchemeTask.didReceive(image.data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame, let size = message.body as? [String: Double],
                let width = size["width"], let height = size["height"],
                width.isFinite, height.isFinite, width > 0, height > 0
            else {
                failed()
                return
            }
            loaded(CGSize(width: width, height: height))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.window?.endEditing(true)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            if (error as NSError).code != NSURLErrorCancelled { failed() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed() }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed() }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
            -> WKNavigationActionPolicy
        {
            navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}
