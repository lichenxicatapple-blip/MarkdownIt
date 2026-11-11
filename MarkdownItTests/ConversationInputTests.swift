import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

@MainActor
final class ConversationInputTests: XCTestCase {
    func testPendingFocusIsFulfilledByTheVisibleLayout() throws {
        let (host, input, _) = try makeFocusFixture()
        host.focus("question")
        XCTAssertFalse(input.isFirstResponder)
        host.setVisible(true)
        XCTAssertTrue(input.isFirstResponder, "A visible layout must fulfill the pending focus request")
    }

    func testBlurCancelsFocusBeforeTheInputBecomesVisible() throws {
        let (host, input, _) = try makeFocusFixture()
        host.focus("question")
        host.blur()
        host.setVisible(true)
        XCTAssertFalse(input.isFirstResponder, "A cancelled request must not reopen the keyboard")
        host.focus("question")
        XCTAssertTrue(input.isFirstResponder)
        host.blur()
        XCTAssertFalse(input.isFirstResponder)
    }

    func testPendingFocusWaitsForWindowAttachment() throws {
        let (host, input, window) = try makeFocusFixture(attached: false)
        host.setVisible(true)
        host.focus("question")
        XCTAssertFalse(input.isFirstResponder)
        window.makeKeyAndVisible()
        XCTAssertTrue(input.isFirstResponder, "Attaching the input must fulfill its pending focus request")
    }

    private func makeFocusFixture(attached: Bool = true) throws -> (
        NativeComposerHost, ConversationTextView, UIWindow
    ) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        if attached { window.makeKeyAndVisible() }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        controller.view.addSubview(webView)
        let host = NativeComposerHost()
        controller.view.addSubview(host.view)
        host.view.frame = CGRect(x: 20, y: 20, width: 300, height: 52)
        host.setVisible(false)
        let input = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ConversationTextView }.first)
        addTeardownBlock { @MainActor in
            host.detach()
            window.isHidden = true
        }
        return (host, input, window)
    }

    func testComposerCentersSingleLineGlyphsWithinItsCapsule() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        controller.view.addSubview(webView)
        let host = NativeComposerHost()
        defer {
            host.detach()
            window.isHidden = true
        }
        controller.view.addSubview(host.view)
        host.view.frame = CGRect(x: 20, y: 20, width: 300, height: 52)
        host.setVisible(true)
        let input = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? ConversationTextView }.first)
        XCTAssertTrue(input.superview === webView.superview)
        XCTAssertFalse(input.isDescendant(of: webView))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        for (epoch, text) in ["哈哈哈", "Hamburg", "Hello 你好"].enumerated() {
            host.setText(id: "question", text: text, epoch: epoch + 1)
            input.setNeedsLayout()
            input.layoutIfNeeded()
            await Task.yield()
            let image = UIGraphicsImageRenderer(size: input.bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(input.bounds)
                input.layer.render(in: context.cgContext)
            }
            let raster = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(raster.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            var rows: [Int] = []
            for y in 0..<raster.height {
                for x in 0..<raster.width {
                    let offset = y * raster.bytesPerRow + x * 4
                    if bytes[offset] < 128 && bytes[offset + 1] < 128 && bytes[offset + 2] < 128 {
                        rows.append(y)
                        break
                    }
                }
            }
            let first = try XCTUnwrap(rows.first, "The input must render actual text")
            let last = try XCTUnwrap(rows.last)
            let glyphCenter = CGFloat(first + last + 1) / 2
            XCTAssertEqual(glyphCenter, input.bounds.midY, accuracy: 2, "Vertical alignment for \(text)")
            let caret = input.caretRect(for: input.endOfDocument)
            XCTAssertEqual(caret.midY, input.bounds.midY, accuracy: 2, "Caret alignment for \(text)")
        }
        for count in [2, 5] {
            input.frame.size.height = ceil(24 + 26.4 * Double(count))
            host.setText(
                id: "question", text: Array(repeating: "Hello 你好", count: count).joined(separator: "\n"),
                epoch: count + 10)
            input.layoutIfNeeded()
            await Task.yield()
            XCTAssertLessThanOrEqual(input.contentSize.height, input.bounds.height + 1, "Multiline text must fit")
            // UIKit's caret can extend into font half-leading. Preserve the
            // requested capsule padding rather than counting that leading twice.
            XCTAssertLessThanOrEqual(
                input.caretRect(for: input.endOfDocument).maxY,
                input.bounds.height - 12, "The final line must retain bottom clearance"
            )
        }
    }

    func testSoftwareReturnAndMultilineInsertionNeverSubmit() {
        let view = ConversationTextView()
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        view.insertText("first")
        view.insertText("\n")
        view.insertText("second\nthird")
        XCTAssertEqual(view.text, "first\nsecond\nthird")
        XCTAssertFalse(submitted)
    }

    func testHardwareReturnSubmitsOnceUntilKeyRelease() {
        let view = ConversationTextView()
        view.text = "a question"
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["a question"])
        view.releaseHardwareReturn()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted.count, 2)
    }

    func testShiftReturnInsertsANewlineWithoutSubmitting() {
        let view = ConversationTextView()
        view.text = "first"
        view.selectedRange = NSRange(location: 5, length: 0)
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: .shift))
        XCTAssertEqual(view.text, "first\n")
        XCTAssertFalse(submitted)
    }

    func testCandidateConfirmationCannotSubmitOrRepeatIntoASubmit() {
        let view = ConversationTextView()
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertFalse(view.handleHardwareReturn(modifiers: []))
        view.unmarkText()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertTrue(submitted.isEmpty)
        view.releaseHardwareReturn()
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["中文"])
    }

    func testBlankReturnDoesNotSubmit() {
        let view = ConversationTextView()
        view.text = " \n"
        var submitted = false
        view.onSubmit = { _ in submitted = true }
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertFalse(submitted)
    }

    func testModifiedShortcutsRemainAvailableToUIKit() {
        let view = ConversationTextView()
        view.text = "question"
        var submitted: [String] = []
        view.onSubmit = { submitted.append($0) }
        for modifiers: UIKeyModifierFlags in [.control, .alternate, .command, [.command, .shift]] {
            XCTAssertFalse(view.handleHardwareReturn(modifiers: modifiers))
        }
        XCTAssertEqual(view.text, "question")
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(view.handleHardwareReturn(modifiers: []))
        XCTAssertEqual(submitted, ["question"])
    }
}
