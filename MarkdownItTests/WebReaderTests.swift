import SwiftUI
import UIKit
import WebKit
import XCTest

@testable import MarkdownIt

final class WebReaderTests: XCTestCase {
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 35, message: @autoclosure () -> String = "Reader did not reach its expected state",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(80))
        }
        XCTFail(message(), file: file, line: line)
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private func diagnostics(_ bridge: ReaderBridge) async throws -> [String: Any] {
        let value = try await bridge.call("diagnostics")
        return try XCTUnwrap(value as? [String: Any])
    }

    @MainActor
    private func waitForMode(_ mode: String, bridge: ReaderBridge) async throws {
        try await waitUntil {
            let status = try await self.diagnostics(bridge)
            let transitioning =
                try await bridge.webView.evaluateJavaScript(
                    "Boolean(document.querySelector('.mdv-app').dataset.modeTransition)") as? Bool
            let editorReady =
                mode != "source"
                || (!bridge.sourceEditor.textView.isHidden && bridge.sourceEditor.textView.isUserInteractionEnabled)
            return status["mode"] as? String == mode && transitioning == false && editorReady
        }
    }

    @MainActor
    private func navigationReader(
        markdown: String? = nil, startingNewDocument: Bool = false, pasteboard: UIPasteboard = .general
    ) async throws -> (
        ReaderSession, ReaderBridge, URL
    ) {
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let session = ReaderSession(
            defaults: defaults, modelSettings: isolatedModelSettings(),
            annotationStore: ReadingAnnotationStore(directory: root.appendingPathComponent("annotations")))
        addTeardownBlock { @MainActor in await session.closeDocument() }
        let text: String
        if let markdown {
            text = markdown
        } else {
            text =
                "# Navigation\n\n"
                + (1...60).map { index in
                    "## Section \(index)\n\n" + String(repeating: "Paragraph content for navigation.\n\n", count: 18)
                        + (index == 60 ? "### Detail 60\n\nFinal content.\n" : "")
                }.joined(separator: "\n")
        }
        let url = root.appendingPathComponent("navigation.md")
        try Data(text.utf8).write(to: url)
        await session.grant(root)
        await session.open(url, startingNewDocument: startingNewDocument)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let bridge = ReaderBridge(session: session, pasteboard: pasteboard)
        addTeardownBlock { @MainActor in
            bridge.detach()
            window.isHidden = true
            if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        // A real MediaQueryList, isolated to this test page, exposes preference changes.
        bridge.webView.configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                    (() => {
                      const original = window.matchMedia.bind(window), query = '(prefers-reduced-motion: reduce)';
                      window.readerTestMotion = original(query);
                      window.matchMedia = value => value === query ? window.readerTestMotion : original(value);
                    })();
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        let readerContainer = ReaderContainer(webView: bridge.webView)
        readerContainer.frame = bridge.webView.frame
        readerContainer.autoresizingMask = bridge.webView.autoresizingMask
        controller.view.addSubview(readerContainer)
        try await waitUntil { bridge.ready && session.rendererReady }
        if try await diagnostics(bridge)["outline"] as? Bool != true { _ = try await bridge.call("toggleOutline") }
        return (session, bridge, root)
    }

    @MainActor
    func testCodeCopyKeepsSingleLinesCompactAndControlsOutsideHorizontalScroll() async throws {
        let code = "let title = \"你好，Markdown! 👋\"\n\tprint(title < \"&\")\n"
        let markdown =
            "# Code\n\nInline `code` stays inline.\n\n```sh\ngit status --short\n```\n\n```swift\n"
            + code + "```\n\n```text\n" + String(repeating: "long/", count: 100) + "\n```\n"
        let pasteboard = isolatedPasteboard()
        let (session, bridge, _) = try await navigationReader(markdown: markdown, pasteboard: pasteboard)
        let geometry =
            try await bridge.webView.callAsyncJavaScript(
                """
                const blocks=[...document.querySelectorAll('.mdv-article .mdv-code-block')];
                const single=blocks[0], pre=single.querySelector('pre'), button=single.querySelector('button');
                const line=document.createRange();line.setStart(pre.querySelector('code').firstChild,0);line.setEnd(pre.querySelector('code').firstChild,1);
                const first=line.getBoundingClientRect(), control=button.getBoundingClientRect(), style=getComputedStyle(pre);
                const long=blocks[2], scroller=long.querySelector('pre'), copy=long.querySelector('button');
                const before=copy.getBoundingClientRect().x;
                const gutters=[0,200,scroller.scrollWidth].map(offset=>{
                  scroller.scrollLeft=offset;
                  const edge=long.getBoundingClientRect(),viewport=scroller.getBoundingClientRect(),control=copy.getBoundingClientRect();
                  return {leading:viewport.left-edge.left,trailing:control.left-viewport.right,
                    inset:parseFloat(getComputedStyle(long).getPropertyValue('--mdv-code-inset')),controlShift:control.x-before};
                });
                return {count:blocks.length,highlighted:!!blocks[1].querySelector('.hljs-keyword'),
                  singleHeight:single.getBoundingClientRect().height,
                  naturalHeight:parseFloat(style.paddingTop)+parseFloat(style.lineHeight)+parseFloat(style.paddingBottom),
                  alignment:Math.abs((control.top+control.bottom)/2-(first.top+first.bottom)/2),
                  targetWidth:control.width,targetHeight:control.height,
                  scroll:scroller.scrollLeft,gutters,controlShift:copy.getBoundingClientRect().x-before,
                  clearOfCode:copy.getBoundingClientRect().left>=scroller.getBoundingClientRect().right};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let value = try XCTUnwrap(geometry)
        XCTAssertEqual(value["count"] as? Int, 3)
        XCTAssertEqual(value["highlighted"] as? Bool, true)
        XCTAssertEqual(
            try XCTUnwrap(value["singleHeight"] as? Double), try XCTUnwrap(value["naturalHeight"] as? Double),
            accuracy: 0.1)
        XCTAssertLessThan(try XCTUnwrap(value["alignment"] as? Double), 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(value["targetWidth"] as? Double), 44)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(value["targetHeight"] as? Double), 44)
        XCTAssertGreaterThan(try XCTUnwrap(value["scroll"] as? Double), 0)
        XCTAssertEqual(value["controlShift"] as? Double, 0)
        XCTAssertEqual(value["clearOfCode"] as? Bool, true)
        let gutters = try XCTUnwrap(value["gutters"] as? [[String: Double]])
        XCTAssertEqual(gutters.count, 3)
        for gutter in gutters {
            let inset = try XCTUnwrap(gutter["inset"])
            XCTAssertEqual(try XCTUnwrap(gutter["leading"]), inset, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(gutter["trailing"]), inset)
            XCTAssertEqual(gutter["controlShift"], 0)
        }
        _ = try await bridge.webView.evaluateJavaScript("document.querySelectorAll('.mdv-code-copy')[1].click()")
        try await waitUntil {
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-code-copy')[1].dataset.copied === 'true'") as? Bool == true
        }
        XCTAssertEqual(pasteboard.string, code)
        let stale =
            try await bridge.webView.callAsyncJavaScript(
                "return await window.webkit.messageHandlers.copyCode.postMessage({token:'stale',text:'wrong document'});",
                arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(stale, false)
        XCTAssertEqual(pasteboard.string, code)
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testCodeCopySupportsCodeFormatsDarkAppearanceAndFeedbackReset() async throws {
        let markdown = """
            # Formats

            ```unknown-language
            <tag>**literal** & 你好</tag>
            ```

                indented code
                second line

            <pre><code>HTML &amp; text\nnext line</code></pre>

            ```mermaid
            flowchart LR
              A --> B
            ```
            """
        let pasteboard = isolatedPasteboard()
        let (session, bridge, _) = try await navigationReader(markdown: markdown, pasteboard: pasteboard)
        let expected = ["<tag>**literal** & 你好</tag>\n", "indented code\nsecond line\n", "HTML & text\nnext line"]
        let count =
            try await bridge.webView.evaluateJavaScript("document.querySelectorAll('.mdv-code-copy').length") as? Int
        XCTAssertEqual(count, expected.count)
        let diagramControls =
            try await bridge.webView.evaluateJavaScript(
                "document.querySelectorAll('.mdv-mermaid .mdv-code-copy').length") as? Int
        XCTAssertEqual(diagramControls, 0)
        let initialPaper =
            try await bridge.webView.evaluateJavaScript(
                "getComputedStyle(document.querySelector('.mdv-code-block')).backgroundColor") as? String
        bridge.webView.overrideUserInterfaceStyle = .dark
        bridge.updateTheme()
        try await waitUntil {
            try await bridge.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
                == true
        }
        let darkPaper =
            try await bridge.webView.evaluateJavaScript(
                "getComputedStyle(document.querySelector('.mdv-code-block')).backgroundColor") as? String
        XCTAssertNotEqual(initialPaper, darkPaper)
        for (index, text) in expected.enumerated() {
            _ = try await bridge.webView.callAsyncJavaScript(
                "document.querySelectorAll('.mdv-code-copy')[index].click();",
                arguments: ["index": index], in: nil, contentWorld: .page)
            try await waitUntil {
                try await bridge.webView.callAsyncJavaScript(
                    "return document.querySelectorAll('.mdv-code-copy')[index].dataset.copied === 'true';",
                    arguments: ["index": index], in: nil, contentWorld: .page) as? Bool == true
            }
            XCTAssertEqual(pasteboard.string, text)
        }
        try await waitUntil {
            try await bridge.webView.evaluateJavaScript(
                "[...document.querySelectorAll('.mdv-code-copy')].every(button=>!button.hasAttribute('data-copied')&&!button.disabled)"
            ) as? Bool == true
        }
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testNewBlankDocumentStartsFocusedInSourceAndSavesThroughSharedHistory() async throws {
        let (session, bridge, _) = try await navigationReader(markdown: "", startingNewDocument: true)
        let url = try XCTUnwrap(session.document?.fileURL)
        let editor = bridge.sourceEditor
        try await waitUntil { editor.textView.isFirstResponder && !editor.textView.isHidden }
        XCTAssertEqual(session.mode, "source")
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        XCTAssertFalse(editor.history.canUndo)
        let text = "A new reading note.\n"
        editor.textView.insertText(text)
        editor.commitInput()
        XCTAssertEqual(editor.history.text, text)
        XCTAssertTrue(bridge.moveSourceHistory(forward: false))
        XCTAssertEqual(editor.history.text, "")
        XCTAssertTrue(bridge.moveSourceHistory(forward: true))
        XCTAssertEqual(editor.history.text, text)
        XCTAssertEqual(session.recentDocuments.documents.count, 1)
        await session.closeDocument()
        XCTAssertNil(session.document)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    @MainActor
    func testLargeMarkdownAndHTMLTextRunsRetainExactAnnotationPositions() async throws {
        let marker = "FINAL_TARGET_8427"
        let body = String(repeating: "资料", count: 262_501)
        for text in [
            "# Long run\n\n" + body + marker + "\n", "# Long run\n\n<div>" + body + "&amp;" + marker + "</div>\n",
        ] {
            let (session, bridge, _) = try await navigationReader(markdown: text)
            let selected = try await bridge.webView.callAsyncJavaScript(
                """
                const run = [...document.querySelectorAll('.mdv-article [data-reader-text]')].find(el => el.textContent.endsWith(marker));
                const node = run.firstChild, at = node.textContent.lastIndexOf(marker);
                const range = document.createRange(); range.setStart(node, at); range.setEnd(node, at + marker.length);
                getSelection().removeAllRanges(); getSelection().addRange(range);
                return getSelection().toString();
                """, arguments: ["marker": marker], in: nil, contentWorld: .page)
            XCTAssertEqual(selected as? String, marker)
            _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
            try await waitUntil { session.annotations.visible.count == 1 }
            let expected = (text as NSString).range(of: marker)
            XCTAssertEqual(
                session.annotations.visible.first?.ranges, [.init(start: expected.location, end: NSMaxRange(expected))])
            XCTAssertEqual(session.document?.text, text)
            XCTAssertNil(session.errorMessage)
        }
    }

    @MainActor
    func testLocalInputToolbarDoesNotReserveAFullWidthReadingStrip() {
        let bounds = CGRect(x: 0, y: 0, width: 1210, height: 802)
        for keyboard in [
            // Captured on iPad with the hardware-keyboard Pinyin toolbar.
            CGRect(x: 5, y: 724.5, width: 65, height: 52.5),
            CGRect(x: 1140, y: 724.5, width: 65, height: 77.5),
            CGRect(x: 440, y: 400, width: 320, height: 260),
            CGRect(x: 0, y: 650, width: 1210, height: 100),
            CGRect(x: 0, y: 802, width: 1210, height: 0),
        ] {
            XCTAssertEqual(ReaderContainer.readingFrame(in: bounds, keyboard: keyboard), bounds)
        }
        let docked = CGRect(x: 0, y: 450, width: 1210, height: 352)
        XCTAssertEqual(
            ReaderContainer.readingFrame(in: bounds, keyboard: docked),
            CGRect(x: 0, y: 0, width: 1210, height: 450))
    }

    @MainActor
    func testReaderViewportUpdatesInputInsetWithoutResizingTheReadingCanvas() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let webView = ReaderWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let viewport = ReaderViewport(webView: webView)
        viewport.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(viewport)
        NSLayoutConstraint.activate([
            viewport.topAnchor.constraint(equalTo: controller.view.topAnchor),
            viewport.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        let input = UITextView(frame: CGRect(x: 16, y: 16, width: 240, height: 100))
        viewport.addSubview(input)
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        try await waitUntil { viewport.bounds.height > 0 && webView.frame == viewport.bounds }
        let canvas = viewport.bounds
        for _ in 0..<2 {
            XCTAssertTrue(input.becomeFirstResponder())
            // Let UIKit update its guide naturally. Forcing the viewport to lay
            // out here would hide the stale native inset seen with local input.
            try await waitUntil(
                timeout: 8,
                message: "Keyboard \(viewport.keyboardLayoutGuide.layoutFrame), inset \(webView.inputBottomInset)"
            ) {
                let inset = viewport.bounds.maxY - viewport.keyboardLayoutGuide.layoutFrame.minY
                return inset > 0 && abs(webView.inputBottomInset - inset) < 1
            }
            XCTAssertEqual(viewport.bounds, canvas)
            XCTAssertEqual(webView.frame, canvas, "Local input avoidance must not resize the reading canvas")
            XCTAssertTrue(input.resignFirstResponder())
            try await waitUntil(timeout: 8) {
                viewport.keyboardLayoutGuide.layoutFrame.minY >= viewport.bounds.maxY - 1
                    && webView.inputBottomInset < 1
            }
            XCTAssertEqual(viewport.bounds, canvas)
        }
    }

    @MainActor
    func testReaderReclaimsKeyboardTrackingForFocusedInputAfterForeignMenus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let webView = ReaderWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let container = ReaderContainer(webView: webView)
        container.frame = controller.view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(container)
        let viewport = try XCTUnwrap(webView.superview as? ReaderViewport)
        let inputs: [UITextView] = [SourceTextView(), ConversationTextView()]
        for (index, input) in inputs.enumerated() {
            input.frame = CGRect(x: 16, y: 16 + index * 110, width: 240, height: 100)
            viewport.addSubview(input)
        }
        let settingsInput = UITextField(frame: CGRect(x: 16, y: 250, width: 240, height: 44))
        controller.view.addSubview(settingsInput)
        let foreignMenu = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(foreignMenu)
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            if previousKeyWindow?.isHidden == false { previousKeyWindow?.makeKey() }
        }
        try await waitUntil { viewport.bounds.height > 0 }
        // UIKit copies a newly registered guide's options into the window's
        // existing shared guide. Native menus use a non-following guide.
        let foreignGuide = foreignMenu.keyboardLayoutGuide
        let sharedGuide = try XCTUnwrap(window.layoutGuides.compactMap { $0 as? UIKeyboardLayoutGuide }.first)
        func disableSharedTracking() {
            foreignGuide.followsUndockedKeyboard = true
            foreignGuide.followsUndockedKeyboard = false
            XCTAssertFalse(sharedGuide.followsUndockedKeyboard)
            XCTAssertTrue(viewport.keyboardLayoutGuide.followsUndockedKeyboard)
        }
        for input in inputs {
            disableSharedTracking()
            XCTAssertTrue(input.becomeFirstResponder())
            XCTAssertTrue(sharedGuide.followsUndockedKeyboard, "Starting reader input must reclaim tracking")
            disableSharedTracking()
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            XCTAssertTrue(sharedGuide.followsUndockedKeyboard, "System input transitions must also reclaim tracking")
            XCTAssertTrue(input.isFirstResponder)
            input.setMarkedText("zhongwen", selectedRange: NSRange(location: 5, length: 0))
            let selection = input.selectedRange
            XCTAssertNotNil(input.markedTextRange)
            disableSharedTracking()
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            XCTAssertTrue(sharedGuide.followsUndockedKeyboard, "Scene restoration must reclaim tracking")
            XCTAssertTrue(input.isFirstResponder, "Restoring the input interface must preserve focus")
            XCTAssertEqual(input.text, "zhongwen", "Restoring input must not discard unconfirmed text")
            XCTAssertEqual(input.selectedRange, selection, "Restoring input must not move the caret")
            XCTAssertNotNil(input.markedTextRange, "Restoring input must not confirm an IME candidate")
            input.unmarkText()
            XCTAssertTrue(settingsInput.becomeFirstResponder())
            disableSharedTracking()
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            XCTAssertFalse(sharedGuide.followsUndockedKeyboard, "Reader policy must not take over settings input")
        }
    }

    @MainActor
    func testReaderViewportTracksDockedKeyboardAcrossAvailableSizeChanges() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let webView = ReaderWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let container = ReaderContainer(webView: webView)
        container.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(container)
        let trailing = container.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
        let bottom = container.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: controller.view.topAnchor),
            container.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            trailing, bottom,
        ])
        let viewport = try XCTUnwrap(webView.superview as? ReaderViewport)
        let input = UITextView(frame: CGRect(x: 16, y: 16, width: 240, height: 100))
        viewport.addSubview(input)
        window.makeKeyAndVisible()
        defer {
            _ = input.resignFirstResponder()
            window.isHidden = true
        }
        XCTAssertTrue(container.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertFalse(container.keyboardLayoutGuide.usesBottomSafeArea)
        try await waitUntil { viewport.bounds.width > 0 && viewport.bounds.height > 0 }
        XCTAssertTrue(input.becomeFirstResponder())
        try await waitUntil(timeout: 8) { container.keyboardLayoutGuide.layoutFrame.height > 0 }
        for (trailingInset, bottomInset) in [(84.0, 0.0), (0.0, 90.0), (84.0, 90.0), (0.0, 0.0)] {
            trailing.constant = -trailingInset
            bottom.constant = -bottomInset
            // Observe the natural layout passes; forcing layout while polling
            // would conceal an obsolete keyboard offset after a size change.
            try await waitUntil(timeout: 8) {
                let guide = container.keyboardLayoutGuide.layoutFrame
                return input.isFirstResponder && guide.height > 0
                    && abs(container.bounds.width - (controller.view.bounds.width - trailingInset)) < 1
                    && abs(container.bounds.height - (controller.view.bounds.height - bottomInset)) < 1
                    && abs(viewport.frame.maxY - guide.minY) < 1 && viewport.bounds.height > 0
            }
            XCTAssertEqual(viewport.frame.maxY, container.keyboardLayoutGuide.layoutFrame.minY, accuracy: 1)
            XCTAssertEqual(webView.frame, viewport.bounds)
        }
        XCTAssertTrue(input.resignFirstResponder())
        try await waitUntil(timeout: 8) {
            abs(viewport.frame.maxY - container.bounds.maxY) < 1
        }
        XCTAssertEqual(
            viewport.frame, container.bounds, "Dismissing the keyboard must restore the full reading viewport")
    }

    @MainActor
    func testDocumentCloseTravelsBetweenEdgesAndRetargetsWithoutTeleporting() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let probe = CloseMotionProbe()
        window.rootViewController = UIHostingController(rootView: CloseMotionProbeView(probe: probe))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await waitUntil { probe.positions.last.map { abs($0 - 300) < 0.5 } == true }
        probe.positions.removeAll()
        probe.destination = 84
        try await Task.sleep(for: .seconds(ReaderDesign.documentCloseDuration + 0.12))
        XCTAssertTrue(probe.positions.contains { $0 > 300.5 }, "Wind-up briefly moves against the travel direction")
        XCTAssertTrue(
            probe.positions.contains { (120...260).contains($0) },
            "The control must cross the document rather than teleport and animate only at its destination")
        XCTAssertEqual(try XCTUnwrap(probe.positions.last), 84, accuracy: 0.5)

        probe.positions.removeAll()
        probe.destination = 300
        try await Task.sleep(for: .milliseconds(200))
        probe.destination = 140
        try await Task.sleep(for: .seconds(ReaderDesign.documentCloseDuration + 0.12))
        XCTAssertEqual(try XCTUnwrap(probe.positions.last), 140, accuracy: 0.5)
        let largestStep = zip(probe.positions, probe.positions.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(largestStep, 80, "Retargeting must keep the visible in-flight position")

        probe.reduceMotion = true
        probe.destination = 40
        try await waitUntil { probe.positions.last.map { abs($0 - 40) < 0.5 } == true }
    }

    @MainActor
    func testFloatingControlsAnimateUnanimatedLayoutAndRespectSystemMotion() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let surface = ReaderControlsSurface()
        controller.view = surface
        window.rootViewController = controller
        let controls = UIView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(controls)
        let top = controls.topAnchor.constraint(equalTo: surface.topAnchor, constant: 100)
        NSLayoutConstraint.activate([
            top,
            controls.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            controls.widthAnchor.constraint(equalToConstant: 44),
            controls.heightAnchor.constraint(equalToConstant: 44),
        ])
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        controls.layer.removeAllAnimations()

        top.constant = 60
        surface.layoutIfNeeded()
        let appearance = try XCTUnwrap(controls.layer.animation(forKey: "position") as? CABasicAnimation)
        XCTAssertEqual(appearance.duration, ReaderDesign.inputAvoidanceDuration, accuracy: 0.01)
        XCTAssertEqual(controls.frame.minY, 60, accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(70))
        let movingY = try XCTUnwrap(controls.layer.presentation()).frame.minY
        XCTAssertGreaterThan(movingY, 60)
        XCTAssertLessThan(movingY, 100)

        top.constant = 100
        surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        let reversedY = try XCTUnwrap(controls.layer.presentation()).frame.minY
        XCTAssertEqual(reversedY, movingY, accuracy: 8, "A new guide update continues from the visible position")
        XCTAssertLessThan(reversedY, 100, "Reversal must not jump directly to its target")

        controls.layer.removeAllAnimations()
        UIView.animate(withDuration: 0.6) {
            top.constant = 40
            surface.layoutIfNeeded()
        }
        let system = try XCTUnwrap(controls.layer.animation(forKey: "position") as? CABasicAnimation)
        XCTAssertEqual(system.duration, 0.6, accuracy: 0.01, "Existing system animation timing must stay in charge")

        controls.layer.removeAllAnimations()
        surface.reduceMotion = true
        top.constant = 100
        surface.layoutIfNeeded()
        XCTAssertNil(controls.layer.animation(forKey: "position"))
        XCTAssertEqual(controls.frame.minY, 100, accuracy: 0.5)
    }

    @MainActor
    func testReaderContainerFillsScreenWhileNativeEditorFollowsKeyboardGuide() async throws {
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keyboard.md")
        try Data(("# Keyboard\n\n" + String(repeating: "A line of editable content.\n", count: 100)).utf8).write(
            to: file)
        await session.open(file)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ReaderScreen(session: session))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            session.bridge?.detach()
            window.isHidden = true
        }
        try await waitUntil { session.rendererReady }
        let bridge = try XCTUnwrap(session.bridge)
        let viewport = try XCTUnwrap(bridge.webView.superview as? ReaderViewport)
        let container = try XCTUnwrap(viewport.superview as? ReaderContainer)
        func controlsSurface(in view: UIView) -> ReaderControlsSurface? {
            if let surface = view as? ReaderControlsSurface { return surface }
            return view.subviews.lazy.compactMap { controlsSurface(in: $0) }.first
        }
        let controls = try XCTUnwrap(controlsSurface(in: window))
        let actions = try XCTUnwrap(controls.subviews.first)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let editor = bridge.sourceEditor.textView
        XCTAssertTrue(editor.superview === viewport)
        XCTAssertFalse(editor.isDescendant(of: bridge.webView))
        func layoutFits() -> Bool {
            let canvas = container.convert(container.bounds, to: window)
            let source = editor.convert(editor.bounds, to: window)
            let boundary = container.convert(container.keyboardLayoutGuide.layoutFrame.origin, to: window).y
            return abs(canvas.maxY - window.bounds.maxY) < 1 && abs(source.maxY - boundary) < 1
                && source.height > 0
        }
        func controlsFit() -> Bool {
            let safeBottom = controls.safeAreaLayoutGuide.layoutFrame.maxY - 16
            let keyboardTop = controls.keyboardLayoutGuide.layoutFrame.minY - ReaderDesign.floatingGap
            return actions.bounds.height > 0 && abs(actions.frame.maxY - min(safeBottom, keyboardTop)) < 1
        }
        try await waitUntil(timeout: 8) { layoutFits() && controlsFit() }
        XCTAssertTrue(controls.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertTrue(container.keyboardLayoutGuide.followsUndockedKeyboard)
        XCTAssertNil(controls.hitTest(CGPoint(x: controls.bounds.midX, y: 10), with: nil))
        XCTAssertNil(controls.hitTest(actions.center, with: nil), "Collapsed action slots must pass touches through")
        let disclosure = CGPoint(x: actions.frame.maxX - ReaderDesign.hitTarget / 2, y: actions.frame.midY)
        XCTAssertNotNil(controls.hitTest(disclosure, with: nil))
        XCTAssertTrue(editor.becomeFirstResponder())
        try await waitUntil(
            timeout: 8,
            message:
                "Container \(container.convert(container.bounds, to: window)), source \(editor.convert(editor.bounds, to: window)), keyboard guide \(container.keyboardLayoutGuide.layoutFrame), first responder \(editor.isFirstResponder)"
        ) { layoutFits() && controlsFit() && container.keyboardLayoutGuide.layoutFrame.height > 0 }
        editor.selectedRange = NSRange(location: editor.text.utf16.count, length: 0)
        editor.insertText("Last edited line.")
        try await waitUntil(
            timeout: 8,
            message:
                "Source \(editor.convert(editor.bounds, to: window)), caret \(editor.selectedTextRange.map { editor.convert(editor.caretRect(for: $0.end), to: window) } ?? .null), keyboard guide \(container.keyboardLayoutGuide.layoutFrame), offset \(editor.contentOffset), selection \(editor.selectedRange), first responder \(editor.isFirstResponder)"
        ) {
            guard let selection = editor.selectedTextRange else { return false }
            let caret = editor.convert(editor.caretRect(for: selection.end), to: window)
            let source = editor.convert(editor.bounds, to: window)
            return layoutFits() && caret.minY >= source.minY && caret.maxY <= source.maxY + 1
        }
        XCTAssertTrue(editor.resignFirstResponder())
        try await waitUntil(timeout: 8) {
            layoutFits() && controlsFit()
                && abs(editor.convert(editor.bounds, to: window).maxY - window.bounds.maxY) < 1
        }
        await session.closeDocument()
    }

    @MainActor
    func testShortDocumentFillsViewportWithoutClippingOutlineOrAddingEmptyScrollArea() async throws {
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("short.md")
        let markdown = "# Short document\n\n## One\n\nLast paragraph.\n"
        try Data(markdown.utf8).write(to: file)
        await session.grant(root)
        await session.open(file)
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let readerContainer = ReaderContainer(webView: bridge.webView)
        readerContainer.frame = bridge.webView.frame
        readerContainer.autoresizingMask = bridge.webView.autoresizingMask
        controller.view.addSubview(readerContainer)
        defer {
            bridge.detach()
            window.isHidden = true
        }
        // Both the tall screenshot case and a short landscape/split-screen
        // viewport must fit. A fixed minimum height hides the latter failure.
        for size in [
            CGSize(width: 1024, height: 1366), CGSize(width: 1024, height: 430), CGSize(width: 390, height: 844),
        ] {
            readerContainer.frame = CGRect(origin: .zero, size: size)
            try await waitUntil { bridge.ready && session.rendererReady }
            try await waitUntil {
                let viewport = try await bridge.webView.evaluateJavaScript("[innerWidth, innerHeight]") as? [Double]
                return viewport == [size.width, size.height]
            }
            if !session.outlineExpanded { _ = try await bridge.call("toggleOutline") }
            try await waitUntil {
                try await bridge.webView.evaluateJavaScript(
                    "!document.querySelector('.mdv-reading-layout').getAnimations().some(a => a.playState === 'running')"
                ) as? Bool == true
            }
            let measured = try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const rect = selector => document.querySelector(selector).getBoundingClientRect();
                  return { height: innerHeight, width: innerWidth,
                    layout: rect('.mdv-reading-layout').height, outline: rect('.mdv-outline').bottom,
                    content: rect('.mdv-article').bottom, scroll: document.documentElement.scrollHeight };
                })()
                """)
            let geometry = try XCTUnwrap(measured as? [String: Double])
            let viewport = try XCTUnwrap(geometry["height"])
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(geometry["layout"]), viewport - 1, "Reader stopped early: \(geometry)")
            // Compact outline has the intended 16px bottom inset.
            XCTAssertEqual(
                try XCTUnwrap(geometry["outline"]), viewport - (size.width <= 560 ? 16 : 0), accuracy: 1,
                "Outline does not cover its viewport: \(geometry)")
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(geometry["scroll"]), viewport + 1,
                "A short document must not create a blank scroll area: \(geometry)")
            XCTAssertLessThan(try XCTUnwrap(geometry["content"]), viewport)
            _ = try await bridge.call("toggleMode")
            try await waitForMode("source", bridge: bridge)
            let sourceGeometry = try await bridge.webView.evaluateJavaScript(
                "document.querySelector('.mdv-app').getBoundingClientRect().height")
            let sourceHeight = try XCTUnwrap(sourceGeometry as? Double)
            XCTAssertEqual(sourceHeight, viewport, accuracy: 1, "Source must use the same full viewport")
            _ = try await bridge.call("toggleMode")
            try await waitForMode("preview", bridge: bridge)
        }
        XCTAssertEqual(session.document?.text, markdown)
        await session.closeDocument()
    }

    @MainActor
    func testLocalImagePermissionRequestsSpecificFoldersAndReloadsWithoutReopeningDocument() async throws {
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notes = root.appendingPathComponent("文档", isDirectory: true)
        let images = notes.appendingPathComponent("images", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for folder in [images, assets] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let svg = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\"><circle cx=\"16\" cy=\"16\" r=\"12\"/></svg>"
                .utf8)
        try svg.write(to: images.appendingPathComponent("同级.svg"))
        try svg.write(to: assets.appendingPathComponent("上级.svg"))
        let file = notes.appendingPathComponent("阅读.md")
        let markdown = "# Local images\n\n![Sibling](images/同级.svg)\n\n![Parent](../assets/上级.svg)\n"
        try Data(markdown.utf8).write(to: file)
        await session.open(file)
        let token = session.documentToken
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        let readerContainer = ReaderContainer(webView: bridge.webView)
        readerContainer.frame = bridge.webView.frame
        readerContainer.autoresizingMask = bridge.webView.autoresizingMask
        controller.view.addSubview(readerContainer)
        defer {
            bridge.detach()
            window.isHidden = true
        }
        try await waitUntil { session.rendererReady && session.resourcePermission != nil }
        XCTAssertEqual(session.resourcePermission?.directory.path, images.path)
        let firstGrant = await session.grant(images)
        XCTAssertTrue(firstGrant)
        session.reloadResources()
        try await waitUntil {
            let loaded = try await self.diagnostics(bridge)["localImages"] as? [[String: Any]] ?? []
            return session.resourcePermission != nil && session.resourcePermission?.directory.path == assets.path
                && loaded.contains {
                    ($0["path"] as? String)?.removingPercentEncoding == "images/同级.svg" && $0["loaded"] as? Bool == true
                }
        }
        let partial = try await diagnostics(bridge)["localImages"] as? [[String: Any]] ?? []
        XCTAssertTrue(
            partial.contains {
                ($0["path"] as? String)?.removingPercentEncoding == "images/同级.svg" && $0["loaded"] as? Bool == true
            })
        let secondGrant = await session.grant(assets)
        XCTAssertTrue(secondGrant)
        session.reloadResources()
        try await waitUntil {
            let images = try await self.diagnostics(bridge)["localImages"] as? [[String: Any]] ?? []
            return images.count == 2 && images.allSatisfy { $0["loaded"] as? Bool == true }
        }
        XCTAssertNil(session.resourcePermission)
        XCTAssertEqual(session.documentToken, token)
        XCTAssertEqual(session.document?.text, markdown)
        await session.closeDocument()
    }

    @MainActor
    func testSavingBeforeRendererReadyPreservesTheNativeWorkingText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("early-save.md")
        let text = "# Original\n\n尚未完成 Web 渲染时，保存仍必须保留原文。\n"
        try Data(text.utf8).write(to: url)
        let session = ReaderSession(
            defaults: UserDefaults(suiteName: UUID().uuidString)!, modelSettings: isolatedModelSettings())
        await session.open(url)
        let bridge = ReaderBridge(session: session)
        defer { bridge.detach() }
        XCTAssertFalse(bridge.ready)
        let saved = await session.flushChanges()
        XCTAssertTrue(saved)
        XCTAssertEqual(session.document?.text, text)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        await session.closeDocument()
    }

    @MainActor
    func testSwitchingDocumentsSavesNativeBufferWithoutAWebSourceRead() async throws {
        let (session, bridge, root) = try await navigationReader()
        let original = try XCTUnwrap(session.document)
        let history = session.recentDocuments.documents
        let incoming = root.appendingPathComponent("next.md")
        try Data("# Next document\n".utf8).write(to: incoming)
        let text = "# Pending native edits\n"
        bridge.sourceEditor.textView.selectedRange = NSRange(location: 0, length: original.text.utf16.count)
        bridge.sourceEditor.textView.insertText(text)
        _ = try await bridge.webView.evaluateJavaScript(
            "window.MarkdownIt.sourceState = () => { throw new Error('renderer unavailable'); }; void 0;")
        await session.open(incoming)
        XCTAssertEqual(session.document?.fileURL, incoming)
        XCTAssertEqual(session.recentDocuments.documents.count, history.count + 1)
        XCTAssertEqual(try String(contentsOf: original.fileURL, encoding: .utf8), text)
        XCTAssertEqual(try String(contentsOf: incoming, encoding: .utf8), "# Next document\n")
        session.bridge = nil
        await session.closeDocument()
    }

    @MainActor
    func testCloseCommitsMarkedNativeTextBeforeSaving() async throws {
        let (session, bridge, _) = try await navigationReader()
        let url = try XCTUnwrap(session.document?.fileURL)
        let editor = bridge.sourceEditor.textView
        let text = "# 最新内容\n\n尚在输入法组合中的原生文本。\n"
        editor.selectedRange = NSRange(location: 0, length: editor.text.utf16.count)
        editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        XCTAssertNotEqual(session.document?.text, text)
        await session.closeDocument()
        XCTAssertNil(session.document)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    @MainActor
    func testSourceHistoryGroupsTypingAndKeepsPasteAndAgentTransactionsSeparate() async throws {
        let (session, bridge, _) = try await navigationReader()
        let original = try XCTUnwrap(session.document?.text)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let editor = bridge.sourceEditor.textView
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: original.utf16.count, length: 0)
        editor.insertText("h")
        editor.insertText("i")
        try await waitUntil { session.canUndoSource }
        let typed = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(typed, original + "hi")
        _ = bridge.moveSourceHistory(forward: false)
        let undone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(undone, original)
        XCTAssertTrue(session.canRedoSource)
        _ = bridge.moveSourceHistory(forward: true)
        editor.insertText("x")
        let afterPaste = original + "hix\nPasted **text**.\n"
        let provider = NSItemProvider(object: "\nPasted **text**.\n" as NSString)
        editor.paste(itemProviders: [provider])
        try await waitUntil { session.document?.text == afterPaste }
        let afterAgent = afterPaste.replacingOccurrences(of: "Pasted **text**.", with: "Rewritten **text**.")
            .replacingOccurrences(of: "# Navigation", with: "# Changed title")
        _ = bridge.applySourceEdit(before: afterPaste, after: afterAgent, id: "one-agent-batch")
        _ = bridge.moveSourceHistory(forward: false, id: "one-agent-batch")
        let batchUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(batchUndone, afterPaste, "All edits in one Agent batch undo together")
        _ = bridge.moveSourceHistory(forward: false)
        let pasteUndone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteUndone, original + "hix", "Paste remains separate from adjacent typing")
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = bridge.moveSourceHistory(forward: true)
        let pasteRedone = try await diagnostics(bridge)["source"] as? String
        XCTAssertEqual(pasteRedone, afterPaste)
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: afterPaste + "New branch.")
        let result = bridge.moveSourceHistory(forward: true)
        XCTAssertEqual(result, false)
        await session.flushChanges()
        XCTAssertEqual(session.document?.text, afterPaste + "New branch.")
    }

    @MainActor
    func testDocumentSectionLinkResolvesNumberedChineseHeadingAndScrollsWithoutNavigation() async throws {
        let markdown =
            "# Document\n\n[头部裁剪逻辑](#432-头部裁剪)\n\n"
            + String(repeating: "Reading content before the target.\n\n", count: 45)
            + "#### 4.3.2 头部裁剪\n\n"
            + String(repeating: "Reading content after the target.\n\n", count: 30)
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        let resolved =
            try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const article = document.querySelector('.mdv-article');
                  const link = article.querySelector('a[href]');
                  const target = document.getElementById(decodeURIComponent(link.getAttribute('href').slice(1)));
                  return { text: target?.textContent || '', headingID: article.querySelector('h4').id,
                    href: link.getAttribute('href') };
                })()
                """) as? [String: String]
        XCTAssertEqual(resolved?["text"], "4.3.2 头部裁剪", "Unresolved section link: \(resolved ?? [:])")
        guard resolved?["text"] == "4.3.2 头部裁剪" else { return }
        let originalURL = bridge.webView.url
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const article = document.querySelector('.mdv-article');
                const original = article.firstElementChild;
                const link = article.querySelector('a[href]');
                const target = article.querySelector('h4');
                const expectedY = parseFloat(getComputedStyle(target).scrollMarginTop) || 0;
                const click = new MouseEvent('click', { bubbles: true, cancelable: true });
                link.dispatchEvent(click);
                await new Promise(resolve => {
                  const started = performance.now();
                  const frame = () => {
                    if (Math.abs(target.getBoundingClientRect().top - expectedY) < 2 || performance.now() - started > 2500) resolve();
                    else requestAnimationFrame(frame);
                  };
                  requestAnimationFrame(frame);
                });
                return { prevented: click.defaultPrevented, sameContent: article.firstElementChild === original,
                  targetY: target.getBoundingClientRect().top, expectedY, scrollY: window.scrollY };
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["prevented"] as? Bool, true)
        XCTAssertEqual(result?["sameContent"] as? Bool, true)
        XCTAssertGreaterThan(result?["scrollY"] as? Double ?? 0, 500)
        XCTAssertEqual(
            result?["targetY"] as? Double ?? .infinity, try XCTUnwrap(result?["expectedY"] as? Double), accuracy: 2)
        XCTAssertEqual(bridge.webView.url, originalURL)
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testSectionLinksPreserveExplicitTargetsEncodedFragmentsDuplicatesAndFootnotes() async throws {
        let markdown = """
            # Document title

            [Title](#document-title)
            [First](#same)
            [Second](#same-1)
            [Collision](#same-1-1)
            [Unicode](#café-κόσμος-你好)
            [Explicit](#custom-target)
            [Reserved](#reserved-1)
            [Percent](#literal%252F)
            [After empty heading](#heading-9)
            [Missing](#missing-target)

            ## Same

            First paragraph.

            ## Same

            Second paragraph.

            ## Same-1

            Collision paragraph.

            ## **Café** `ΚΌΣΜΟΣ` 你好!

            Unicode paragraph.

            <h2 id="custom-target">Explicit target</h2>
            <h2 id="reserved">Explicit reservation</h2>

            ## Reserved

            <h2 id="literal%2F">Literal percent target</h2>

            ##

            ## Heading-9

            Footnote reference.[^note]

            [^note]: Footnote content.
            """
        let (_, bridge, _) = try await navigationReader(markdown: markdown)
        let result =
            try await bridge.webView.evaluateJavaScript(
                """
                (() => {
                  const article = document.querySelector('.mdv-article');
                  const targets = [...article.querySelectorAll('a[href^="#"]')].map(link => {
                    const target = document.getElementById(decodeURIComponent(link.getAttribute('href').slice(1)));
                    return { label: link.textContent, text: target?.textContent.trim() || '',
                      found: !!target && article.contains(target) };
                  });
                  const missing = [...article.querySelectorAll('a')].find(link => link.textContent === 'Missing');
                  const click = new MouseEvent('click', { bubbles: true, cancelable: true });
                  missing.dispatchEvent(click);
                  return { targets, ids: [...article.querySelectorAll('[id]')].map(element => element.id),
                    missingPrevented: click.defaultPrevented };
                })()
                """) as? [String: Any]
        let targets = try XCTUnwrap(result?["targets"] as? [[String: Any]])
        for (label, text) in [
            "Title": "Document title", "First": "Same", "Second": "Same", "Collision": "Same-1",
            "Unicode": "Café ΚΌΣΜΟΣ 你好!", "Explicit": "Explicit target", "Reserved": "Reserved",
            "Percent": "Literal percent target",
            "After empty heading": "Heading-9",
        ] {
            let target = try XCTUnwrap(targets.first { $0["label"] as? String == label })
            XCTAssertEqual(target["text"] as? String, text, label)
            XCTAssertEqual(target["found"] as? Bool, true, label)
        }
        let ids = try XCTUnwrap(result?["ids"] as? [String])
        XCTAssertEqual(
            Set(ids).count, ids.count, "Generated targets must not collide with headings or explicit HTML IDs")
        XCTAssertEqual(
            targets.filter { $0["found"] as? Bool != true }.count, 1,
            "Only the intentionally missing link is unresolved")
        XCTAssertEqual(
            result?["missingPrevented"] as? Bool, true, "A missing fragment must not navigate away from the reader")
        let status = try await diagnostics(bridge)
        XCTAssertEqual(status["source"] as? String, markdown)
    }

    @MainActor
    func testOutlineAvailabilityFollowsDocumentEditsAndPreservesEmptyHeadings() async throws {
        let (session, bridge, _) = try await navigationReader()
        XCTAssertTrue(session.hasOutline)
        let originalHeadings = try await diagnostics(bridge)["headings"] as? [String]
        XCTAssertEqual(originalHeadings?.first, "Navigation", "The leading H1 belongs in the outline")
        let titleOnly = "# Document title\n\nReading content.\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: titleOnly)
        try await waitUntil {
            try await self.diagnostics(bridge)["headings"] as? [String] == ["Document title"]
        }
        XCTAssertTrue(session.hasOutline, "A single H1 is still a document heading")
        for markdown in [
            "", "Plain reading content.\n",
            "```markdown\n## This is code, not a heading\n```\n",
        ] {
            _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: markdown)
            try await waitUntil { !session.hasOutline && !session.outlineExpanded }
            _ = try await bridge.call("toggleOutline")
            let status = try await diagnostics(bridge)
            XCTAssertEqual(status["outline"] as? Bool, false)
            XCTAssertEqual(status["source"] as? String, markdown)
            try await waitUntil {
                try await bridge.webView.evaluateJavaScript(
                    """
                    (() => {
                      const outline = document.querySelector('.mdv-outline');
                      const layout = document.querySelector('.mdv-reading-layout');
                      const workspace = document.querySelector('.mdv-workspace');
                      return outline.hidden && !layout.classList.contains('mdv-with-outline')
                        && Math.abs(workspace.getBoundingClientRect().left - layout.getBoundingClientRect().left) < 1;
                    })()
                    """) as? Bool == true
            }
        }

        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        let edited = "Reading content.\n\n## Added section\n\nMore content.\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: edited)
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        try await waitUntil { session.hasOutline && session.outlineExpanded }
        let editedStatus = try await diagnostics(bridge)
        XCTAssertEqual(editedStatus["headings"] as? [String], ["Added section"])

        let emptyHeading = "Reading content.\n\n##\n"
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: emptyHeading)
        try await waitUntil { session.hasOutline }
        let status = try await diagnostics(bridge)
        XCTAssertEqual(status["headings"] as? [String], [""])
        XCTAssertEqual(status["source"] as? String, emptyHeading)
    }

    @MainActor
    func testOutlineNavigationPreservesContentAndDestination() async throws {
        let (_, bridge, _) = try await navigationReader()
        let result = try await bridge.webView.callAsyncJavaScript(
            """
            return await new Promise(resolve => {
              const article = document.querySelector('.mdv-article');
              const layout = document.querySelector('.mdv-reading-layout');
              const links = [...document.querySelectorAll('[data-toc-target]')];
              const target = links[31];
              const destination = document.getElementById(target.dataset.tocTarget);
              const originalContent = article.firstElementChild;
              let replaced = 0;
              const observer = new MutationObserver(records => { replaced += records.length; });
              observer.observe(article, { childList: true });
              const started = performance.now(), frames = [];
              target.click();
              const sample = now => {
                frames.push({ ms: now - started, y: window.scrollY,
                  targetY: destination.getBoundingClientRect().top,
                  current: document.querySelector('[aria-current="location"]')?.textContent || '',
                  opacity: Number(getComputedStyle(layout).opacity),
                  visible: article.getClientRects().length > 0,
                  sameContent: article.firstElementChild === originalContent });
                if (now - started < 2200) { requestAnimationFrame(sample); return; }
                observer.disconnect();
                resolve({ target: target.textContent, replaced, frames,
                  tapHighlight: getComputedStyle(target).webkitTapHighlightColor });
              };
              requestAnimationFrame(sample);
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        let probe = try XCTUnwrap(result as? [String: Any])
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: probe, options: .prettyPrinted),
            uniformTypeIdentifier: "public.json")
        attachment.name = "outline-navigation-frame-trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        let frames = try XCTUnwrap(probe["frames"] as? [[String: Any]])
        XCTAssertEqual(
            probe["tapHighlight"] as? String, "rgba(0, 0, 0, 0)",
            "The outline already supplies selection feedback; WebKit must not draw a second gray overlay")
        XCTAssertEqual(probe["replaced"] as? Int, 0)
        XCTAssertTrue(
            frames.allSatisfy {
                $0["visible"] as? Bool == true && $0["sameContent"] as? Bool == true && $0["opacity"] as? Double == 1
            })
        XCTAssertTrue(
            frames.allSatisfy { $0["current"] as? String == probe["target"] as? String },
            "A clicked destination must remain selected throughout navigation")
        XCTAssertLessThan(abs(frames.last?["targetY"] as? Double ?? .infinity), 120)
    }

    @MainActor
    func testOutlineTracksTheSectionAtTheReadingViewportFocus() async throws {
        let markdown =
            "# Reading\n\n"
            + (1...12).map { index in
                "## Section \(index)\n\n" + String(repeating: "A short section with readable content.\n\n", count: 4)
            }.joined(separator: "\n")
        let (_, bridge, _) = try await navigationReader(markdown: markdown)
        let result = try await bridge.webView.callAsyncJavaScript(
            """
            const headings = [...document.querySelectorAll('.mdv-article h2')];
            const samples = [];
            for (const index of [4, 5, 4]) {
              const heading = headings[index];
              const movement = heading.getBoundingClientRect().top - innerHeight / 3 + 12;
              // User scrolling releases the semantic anchor held during reflow.
              document.querySelector('.mdv-article').dispatchEvent(new WheelEvent('wheel', {deltaY: movement, bubbles: true}));
              window.scrollTo({ top: window.scrollY + movement, behavior: 'instant' });
              for (let frame = 0; frame < 4; frame++) await new Promise(requestAnimationFrame);
              samples.push({ expected: heading.textContent,
                current: document.querySelector('[aria-current="location"]')?.textContent,
                start: heading.getBoundingClientRect().top,
                end: headings[index + 1].getBoundingClientRect().top, focus: innerHeight / 3 });
            }
            return samples;
            """, arguments: [:], in: nil, contentWorld: .page)
        let samples = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(samples.count, 3)
        for sample in samples {
            XCTAssertLessThan(try XCTUnwrap(sample["start"] as? Double), try XCTUnwrap(sample["focus"] as? Double))
            XCTAssertGreaterThan(try XCTUnwrap(sample["end"] as? Double), try XCTUnwrap(sample["focus"] as? Double))
            XCTAssertEqual(sample["current"] as? String, sample["expected"] as? String)
        }
    }

    @MainActor
    func testOutlineCentersCurrentChapterAndRetargetsSmoothlyWithoutOverridingManualBrowse() async throws {
        let (_, bridge, _) = try await navigationReader()
        let result = try await bridge.webView.callAsyncJavaScript(
            """
            const body = document.querySelector('.mdv-outline-body');
            const reader = document.querySelector('.mdv-article');
            const links = [...reader.querySelectorAll('h2,h3')].map(heading =>
              document.querySelector(`[data-toc-target="${CSS.escape(heading.id)}"]`));
            const headings = links.map(link => document.getElementById(link.dataset.tocTarget));
            const frame = () => new Promise(requestAnimationFrame);
            const settle = async (ready = () => true) => {
              // Begin timing after WebKit has had a rendering opportunity.
              await frame();
              const started = performance.now();
              let previous = body.scrollTop, stable = 0;
              while (performance.now() - started < 1800) {
                await frame();
                const position = body.scrollTop;
                stable = Math.abs(position - previous) < .2 ? stable + 1 : 0;
                previous = position;
                if (stable >= 5 && performance.now() - started > 100 && ready()) break;
              }
            };
            const measure = () => {
              const selected = document.querySelector('[aria-current="location"]');
              const row = selected.getBoundingClientRect(), pane = body.getBoundingClientRect();
              return { current: selected.textContent, offset: body.scrollTop,
                maximum: body.scrollHeight - body.clientHeight, height: body.clientHeight,
                centerError: row.top + row.height / 2 - (pane.top + body.clientTop + body.clientHeight / 2),
                documentY: window.scrollY };
            };
            const readAt = async (index, following = true) => {
              headings[index].scrollIntoView({ block: 'start', behavior: 'instant' });
              const documentY = window.scrollY;
              await settle(() => {
                const current = measure();
                const target = Math.max(0, Math.min(current.maximum, current.offset + current.centerError));
                return current.current === links[index].textContent && (!following || Math.abs(current.offset - target) < 2);
              });
              return { ...measure(), expectedDocumentY: documentY };
            };
            const centered = await readAt(17);
            body.dispatchEvent(new WheelEvent('wheel', { deltaY: -200, bubbles: true }));
            body.scrollTop = 0;
            window.scrollBy({ top: 12, behavior: 'instant' });
            await settle();
            const manualSameChapter = measure();
            // Momentum may change chapters after the reader starts browsing the outline.
            const manualDuringMomentum = await readAt(18, false);
            reader.dispatchEvent(new WheelEvent('wheel', { deltaY: 200, bubbles: true }));
            const resumed = await readAt(20);
            const trace = [], sequence = [28, 12, 30, 15, 29], started = performance.now();
            let index = 0;
            while (performance.now() - started < 1100) {
              const now = await frame(), elapsed = now - started;
              if (index < sequence.length && elapsed >= index * 75) {
                headings[sequence[index++]].scrollIntoView({ block: 'start', behavior: 'instant' });
              }
              trace.push({ ms: elapsed, offset: body.scrollTop, current: measure().current });
            }
            await settle();
            const rapid = measure();
            const reopenedDocumentY = window.scrollY;
            body.dispatchEvent(new Event('touchstart', { bubbles: true }));
            body.scrollTop = 0;
            window.MarkdownIt.toggleOutline(); window.MarkdownIt.toggleOutline();
            await settle();
            const reopened = measure();
            reader.dispatchEvent(new WheelEvent('wheel', { deltaY: 200, bubbles: true }));
            const end = await readAt(headings.length - 1);
            const start = await readAt(0);
            const query = window.readerTestMotion;
            Object.defineProperty(query, 'matches', { value: true, configurable: true });
            query.dispatchEvent(new MediaQueryListEvent('change', { matches: true, media: query.media }));
            headings[24].scrollIntoView({ block: 'start', behavior: 'instant' });
            const reducedFrames = [body.scrollTop];
            for (let step = 0; step < 4; step++) { await frame(); reducedFrames.push(body.scrollTop); }
            const reduced = measure();
            await readAt(headings.length - 1);
            const parent = links[59], branchToggle = parent.parentElement.querySelector('[data-collapse-heading]');
            branchToggle.click();
            await settle();
            window.MarkdownIt.toggleOutline(); window.MarkdownIt.toggleOutline();
            await settle();
            const collapsed = { ...measure(), expanded: branchToggle.getAttribute('aria-expanded') };
            return { centered, manualSameChapter, manualDuringMomentum, resumed, trace, rapid,
              reopened, reopenedDocumentY, end, start, reduced, reducedFrames, collapsed };
            """, arguments: [:], in: nil, contentWorld: .page)
        let probe = try XCTUnwrap(result as? [String: Any])
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: probe, options: .prettyPrinted),
            uniformTypeIdentifier: "public.json")
        attachment.name = "outline-center-and-rapid-follow-trace"
        attachment.lifetime = .keepAlways
        add(attachment)
        for (name, chapter) in [
            ("centered", "Section 18"), ("resumed", "Section 21"), ("rapid", "Section 30"),
        ] {
            let state = try XCTUnwrap(probe[name] as? [String: Any])
            XCTAssertEqual(state["current"] as? String, chapter, name)
            XCTAssertEqual(state["centerError"] as? Double ?? .infinity, 0, accuracy: 2, name)
            if let expectedY = state["expectedDocumentY"] as? Double {
                XCTAssertEqual(
                    state["documentY"] as? Double ?? .infinity, expectedY, accuracy: 1,
                    "Following must scroll only the outline pane")
            }
        }
        for name in ["manualSameChapter", "manualDuringMomentum"] {
            let state = try XCTUnwrap(probe[name] as? [String: Any])
            XCTAssertEqual(
                state["offset"] as? Double ?? .infinity, 0, accuracy: 1, "Manual browsing must remain in control")
        }
        let reopened = try XCTUnwrap(probe["reopened"] as? [String: Any])
        XCTAssertEqual(reopened["current"] as? String, "Section 30")
        XCTAssertEqual(
            reopened["offset"] as? Double ?? .infinity, 0, accuracy: 1,
            "Switching panels preserves manual directory browsing")
        XCTAssertEqual(reopened["documentY"] as? Double, probe["reopenedDocumentY"] as? Double)
        let start = try XCTUnwrap(probe["start"] as? [String: Any])
        let end = try XCTUnwrap(probe["end"] as? [String: Any])
        XCTAssertEqual(start["offset"] as? Double ?? .infinity, 0, accuracy: 1)
        XCTAssertEqual(end["offset"] as? Double ?? .infinity, end["maximum"] as? Double ?? -.infinity, accuracy: 1)
        let trace = try XCTUnwrap(probe["trace"] as? [[String: Any]])
        let height = try XCTUnwrap((probe["rapid"] as? [String: Any])?["height"] as? Double)
        let offsets = trace.compactMap { $0["offset"] as? Double }
        XCTAssertGreaterThan(
            Set(offsets.map { Int($0.rounded()) }).count, 12, "Rapid following must show intermediate frames")
        for (previous, next) in zip(trace, trace.dropFirst()) {
            let elapsed = (next["ms"] as? Double ?? 0) - (previous["ms"] as? Double ?? 0)
            if elapsed < 40 {
                XCTAssertLessThan(
                    abs((next["offset"] as? Double ?? 0) - (previous["offset"] as? Double ?? 0)), height / 3,
                    "A frame must not jump across the pane")
            }
        }
        let reduced = try XCTUnwrap(probe["reduced"] as? [String: Any])
        XCTAssertEqual(reduced["current"] as? String, "Section 25")
        XCTAssertEqual(reduced["centerError"] as? Double ?? .infinity, 0, accuracy: 2)
        let reducedFrames = try XCTUnwrap(probe["reducedFrames"] as? [Double])
        XCTAssertEqual(
            Set(reducedFrames).count, 2, "Reduce Motion must position directly without intermediate scrolling")
        let collapsed = try XCTUnwrap(probe["collapsed"] as? [String: Any])
        XCTAssertEqual(collapsed["current"] as? String, "Section 60")
        XCTAssertEqual(
            collapsed["expanded"] as? String, "false",
            "Following and reopening must preserve a manually collapsed branch")
    }

    @MainActor
    func testOfflineRenderingEditingPositionsAndSelection() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("https://reader.example.test/v1", forKey: "model.baseURL")
        defaults.set("fixture-model", forKey: "model.id")
        let session = ReaderSession(
            defaults: defaults, modelKey: { "fixture-key" }, modelSettings: isolatedModelSettings())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sample = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Sample"))
        try FileManager.default.copyItem(at: sample, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reading-guide.md")
        // Remote-image loading is independent of the offline document engine.
        let original = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(
                of: "https://cdn.jsdelivr.net/gh/mdn/shared-assets@main/images/examples/balloons.jpg",
                with: "images/market-structure.svg")
        try Data(original.utf8).write(to: url)
        await session.grant(root)
        await session.open(url)
        let bridge = ReaderBridge(session: session)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        bridge.webView.frame = controller.view.bounds
        bridge.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let readerContainer = ReaderContainer(webView: bridge.webView)
        readerContainer.frame = bridge.webView.frame
        readerContainer.autoresizingMask = bridge.webView.autoresizingMask
        controller.view.addSubview(readerContainer)
        defer {
            // End the fixture's input session before hiding its temporary window.
            window.endEditing(true)
            bridge.detach()
            window.isHidden = true
        }
        try await waitUntil { bridge.ready && session.rendererReady }
        try await waitUntil {
            let status = try await bridge.call("diagnostics") as? [String: Any]
            let images = status?["localImages"] as? [[String: Any]] ?? []
            return !images.isEmpty && images.allSatisfy { $0["loaded"] as? Bool == true }
        }
        var status = try await diagnostics(bridge)
        XCTAssertEqual(status["source"] as? String, original)
        XCTAssertEqual(status["math"] as? Int, 7)
        XCTAssertEqual(status["diagrams"] as? Int, 6)
        XCTAssertEqual(status["diagramErrors"] as? Int, 0)
        XCTAssertGreaterThan(status["tables"] as? Int ?? 0, 0)
        XCTAssertGreaterThan((status["headings"] as? [String])?.count ?? 0, 25)
        XCTAssertEqual(status["overflow"] as? Bool, false)
        XCTAssertNil(session.resourcePermission)

        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 150])
        status = try await diagnostics(bridge)
        let before = try XCTUnwrap((status["anchor"] as? [String: Any])?["line"] as? Double)
        for expected in ["source", "preview", "source", "preview"] {
            _ = try await bridge.call("toggleMode")
            try await waitForMode(expected, bridge: bridge)
            let result = try await diagnostics(bridge)
            let after = try XCTUnwrap((result["anchor"] as? [String: Any])?["line"] as? Double)
            XCTAssertEqual(after, before, accuracy: 0.6, "Repeated switches must not accumulate drift")
        }
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = try await bridge.call("scrollToSourceLine", arguments: ["payload": 260])
        _ = try await bridge.call("toggleMode")
        try await waitForMode("preview", bridge: bridge)
        let followed = try await diagnostics(bridge)
        let followedLine = try XCTUnwrap((followed["anchor"] as? [String: Any])?["line"] as? Double)
        XCTAssertEqual(followedLine, 260, accuracy: 1.5)

        let edited =
            original + """

                ## Native edit verification

                <details><summary>HTML summary</summary><p>HTML content</p></details>
                <script>window.jmInjected = true;</script>
                <img src="images/market-structure.svg" onerror="window.jmInjected = true;">
                <iframe src="https://example.test"></iframe>

                """
        _ = bridge.sourceEditor.replace(expected: bridge.sourceEditor.history.text, with: edited)
        await session.flushChanges()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
        status = try await diagnostics(bridge)
        XCTAssertTrue((status["headings"] as? [String])?.contains("Native edit verification") == true)
        XCTAssertEqual(status["unsafeTags"] as? Int, 0)
        let injection = try await bridge.webView.evaluateJavaScript("Boolean(window.jmInjected)") as? Bool
        XCTAssertEqual(injection, false)
        let eventHandlers =
            try await bridge.webView.evaluateJavaScript("document.querySelectorAll('.mdv-article [onerror]').length")
            as? Int
        XCTAssertEqual(eventHandlers, 0)

        // A system context menu must suppress Ask while preserving the native selection.
        _ = try await bridge.webView.evaluateJavaScript(
            """
            const paragraph = document.querySelector('.mdv-article p');
            const range = document.createRange(); range.selectNodeContents(paragraph);
            const selected = window.getSelection(); selected.removeAllRanges(); selected.addRange(range);
            """)
        _ = try await bridge.call("suppressSelection")
        status = try await diagnostics(bridge)
        XCTAssertEqual(status["questionVisible"] as? Bool, false)
        XCTAssertFalse((status["selectedText"] as? String ?? "").isEmpty)
        _ = try await bridge.call("askSelection")
        try await waitUntil { session.agentOpen }
        let collapse = bridge.conversationPanel.collapseButton
        try await waitUntil { !collapse.isHidden && collapse.bounds.width > 0 }
        XCTAssertEqual(collapse.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(collapse.configuration?.image?.isSymbolImage, true)
        XCTAssertEqual(ReaderDesign.agentControlIcon, 16)
        let agentResult = try await bridge.call("agentDiagnostics")
        var agent = try XCTUnwrap(agentResult as? [String: Any])
        XCTAssertTrue((agent["reference"] as? String ?? "").contains(status["selectedText"] as? String ?? ""))
        await session.closeAgent()
        _ = try await bridge.call("toggleMode")
        try await waitForMode("source", bridge: bridge)
        _ = bridge.sourceEditor.replace(
            expected: bridge.sourceEditor.history.text,
            with: "# Earlier section\n\nEarlier text.\n\n## Updated source\n\nSelected phrase.\n")
        bridge.sourceEditor.textView.selectedRange = (bridge.sourceEditor.history.text as NSString).range(
            of: "Selected phrase")
        _ = try await bridge.call("askSelection")
        try await waitUntil { session.agentOpen }
        let sourceAgentResult = try await bridge.call("agentDiagnostics")
        agent = try XCTUnwrap(sourceAgentResult as? [String: Any])
        XCTAssertTrue((agent["reference"] as? String ?? "").contains("Selected phrase"))
        XCTAssertFalse((agent["reference"] as? String ?? "").contains("Earlier text"))
        await session.closeAgent()
        await session.flushChanges()
        let closed = await session.document?.closeSavingChanges()
        XCTAssertEqual(closed, true)
    }
}

@MainActor
private final class CloseMotionProbe: ObservableObject {
    @Published var destination: CGFloat = 300
    @Published var reduceMotion = false
    var positions: [CGFloat] = []
}

private struct CloseMotionProbeView: View {
    @ObservedObject var probe: CloseMotionProbe

    var body: some View {
        Color.clear.overlay(alignment: .topLeading) {
            Color.clear.frame(width: 44, height: 44)
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minX }) {
                    probe.positions.append($0)
                }
                .modifier(ReaderDocumentCloseMotion(destination: probe.destination, reduceMotion: probe.reduceMotion))
        }
    }

}

extension WebReaderTests {
    @MainActor
    func testUnderlinesJoinAcrossFormattingWithoutSwallowingUnmarkedText() async throws {
        let markdown = "# Notes\n\nplain`code`tail other\n"
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        for phrase in ["plain", "code", "tail", "other"] {
            _ = try await bridge.webView.callAsyncJavaScript(
                """
                const run=[...document.querySelectorAll('.mdv-article p [data-reader-text]')].find(e=>e.textContent.includes(phrase));
                const walker=document.createTreeWalker(run,NodeFilter.SHOW_TEXT);let node;
                while(node=walker.nextNode())if(node.textContent.includes(phrase))break;
                const first=node.textContent.indexOf(phrase),range=document.createRange();range.setStart(node,first);range.setEnd(node,first+phrase.length);
                getSelection().removeAllRanges();getSelection().addRange(range);
                """, arguments: ["phrase": phrase], in: nil, contentWorld: .page)
            _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
            try await waitUntil {
                session.annotations.visible.contains { record in
                    let location = (markdown as NSString).range(of: phrase).location
                    return record.ranges.contains { $0.start <= location && $0.end >= location + phrase.utf16.count }
                }
            }
            await session.waitForAnnotations()
        }
        XCTAssertEqual(session.annotations.visible.count, 2)
        let joined = try XCTUnwrap(session.annotations.visible.first)
        let pieces = joined.ranges.map {
            (markdown as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
        }
        XCTAssertEqual(pieces, ["plain", "code", "tail"])
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testWavesCoverInlineCodeBetweenOrdinaryText() async throws {
        let markdown = "# Notes\n\n普通文字，以及 `inline code` 标签。\n"
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        _ = try await bridge.webView.callAsyncJavaScript(
            """
            const range=document.createRange();range.selectNodeContents(document.querySelector('.mdv-article p'));
            getSelection().removeAllRanges();getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
        try await waitUntil { session.annotations.visible.count == 1 }
        await session.waitForAnnotations()
        let result =
            try await bridge.webView.callAsyncJavaScript(
                """
                const code=document.querySelector('.mdv-article p code').getBoundingClientRect();
                const waves=[...document.querySelectorAll('.jm-annotation-waves svg')].map(e=>{const r=e.getBoundingClientRect();return{left:r.left,right:r.right,top:r.top,bottom:r.bottom};});
                return {code:{left:code.left,right:code.right,top:code.top,bottom:code.bottom},waves,
                  covered:waves.some(r=>r.left<=code.left+code.width/2&&r.right>=code.left+code.width/2)};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["covered"] as? Bool, true, "\(String(describing: result))")
        let code = (markdown as NSString).range(of: "inline code")
        XCTAssertTrue(
            session.annotations.visible.first?.ranges.contains {
                $0.start <= code.location && $0.end >= NSMaxRange(code)
            } == true)
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testAnnotationsUseExactSourcePositionsAcrossFormattingCodeAndTables() async throws {
        let markdown =
            "# Notes\n\nsame **same** same &amp; `inline code`\n\n| one | two |\n| --- | --- |\n| cell | **bold cell** |\n\n```swift\nlet value = 42\n```\n"
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        for (selector, phrase) in [
            ("strong", "same"), ("code", "inline code"), ("td strong", "bold cell"), ("pre code", "let value = 42\n"),
        ] {
            _ = try await bridge.webView.callAsyncJavaScript(
                """
                const element=[...document.querySelectorAll('.mdv-article '+selector)].find(e=>e.textContent===phrase);
                if(!element)throw Error('Missing selected content');
                const range=document.createRange();range.selectNodeContents(element);
                const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
                """, arguments: ["selector": selector, "phrase": phrase], in: nil, contentWorld: .page)
            _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
            try await waitUntil {
                session.annotations.visible.contains { note in
                    note.ranges.contains { range in
                        (markdown as NSString).substring(
                            with: NSRange(location: range.start, length: range.end - range.start)) == phrase
                    }
                }
            }
        }
        XCTAssertEqual(session.annotations.visible.count, 4)
        XCTAssertEqual(session.document?.text, markdown)
        let spans =
            try await bridge.webView.evaluateJavaScript(
                "[...document.querySelectorAll('.jm-annotation-wave')].map(e=>e.textContent)") as? [String]
        XCTAssertTrue(try XCTUnwrap(spans).contains("same"))
        let bold = (markdown as NSString).range(of: "**same**")
        let expected = AnnotationRange(start: bold.location + 2, end: NSMaxRange(bold) - 2)
        let marked = try XCTUnwrap(session.annotations.visible.first { $0.ranges == [expected] })
        XCTAssertTrue(marked.underlined)
    }

    @MainActor
    func testNativeAnnotationCardSavesAndReopensWithoutChangingMarkdown() async throws {
        let markdown = "# Notes\n\nA sentence worth remembering.\n"
        let (session, bridge, root) = try await navigationReader(markdown: markdown)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            const element=document.querySelector('.mdv-article p');
            const range=document.createRange();range.selectNodeContents(element);
            getSelection().removeAllRanges();getSelection().addRange(range);
            """)
        _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "note"]])
        try await waitUntil { bridge.annotationHost.card != nil }
        let card = try XCTUnwrap(bridge.annotationHost.card)
        try await waitUntil {
            try await bridge.webView.evaluateJavaScript("(CSS.highlights.get('jm-annotation-active')?.size || 0)>0")
                as? Bool == true
        }
        XCTAssertTrue(session.annotations.visible.isEmpty, "An unsaved draft only highlights its associated text")
        XCTAssertTrue(card.textView.isFirstResponder)
        card.textView.insertText("Keep this question open.\n再想一想。")
        func find(_ view: UIView, identifier: String) -> UIButton? {
            if view.accessibilityIdentifier == identifier { return view as? UIButton }
            return view.subviews.compactMap { find($0, identifier: identifier) }.first
        }
        let done = try XCTUnwrap(find(card, identifier: "AnnotationDone"))
        XCTAssertTrue(done.isEnabled)
        done.sendActions(for: .touchUpInside)
        try await waitUntil {
            session.annotations.visible.first?.note == "Keep this question open.\n再想一想。"
                && bridge.annotationHost.card == nil
        }
        XCTAssertEqual(session.document?.text, markdown)
        let record = try XCTUnwrap(session.annotations.visible.first)
        XCTAssertFalse(record.underlined)
        await session.closeDocument()
        await session.open(root.appendingPathComponent("navigation.md"))
        bridge.update()
        try await waitUntil { session.rendererReady }
        XCTAssertEqual(session.annotations.visible.first?.note, record.note)
        XCTAssertEqual(session.annotations.visible.first?.id, record.id)
    }

    @MainActor
    func testAnnotationCardScrollsWithTheNativeDocumentUntilCompletelyOffscreen() async throws {
        let (session, bridge, _) = try await navigationReader()
        let text = try XCTUnwrap(session.document?.text)
        let source = (text as NSString).range(of: "Paragraph content for navigation.")
        let ranges = [AnnotationRange(start: source.location, end: NSMaxRange(source))]
        let saved = await session.setAnnotation(
            ranges: ranges, note: "A short note", token: session.documentToken,
            sourceRevision: bridge.sourceEditor.history.revision)
        XCTAssertTrue(saved)
        _ = try await bridge.webView.evaluateJavaScript(
            """
            const element=document.querySelector('.jm-annotation-note');
            const rect=element.getBoundingClientRect();
            element.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:rect.x+rect.width/2,clientY:rect.y+rect.height/2}));
            """)
        try await waitUntil { bridge.annotationHost.card != nil }
        let card = try XCTUnwrap(bridge.annotationHost.card)
        XCTAssertTrue(card.superview === bridge.webView.scrollView)
        let frame = card.frame
        let scroll = bridge.webView.scrollView
        scroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        XCTAssertTrue(bridge.annotationHost.card === card)
        XCTAssertEqual(card.frame, frame)
        scroll.setContentOffset(
            CGPoint(x: 0, y: frame.maxY + card.layer.shadowRadius * 2 + abs(card.layer.shadowOffset.height) + 1),
            animated: false)
        try await waitUntil { bridge.annotationHost.card == nil }
        scroll.setContentOffset(.zero, animated: false)
        XCTAssertNil(bridge.annotationHost.card)
    }

}

extension WebReaderTests {
    @MainActor
    func testPencilWaveKeepsTextAndDrawingNodesStableUntilNativeCommit() async throws {
        let markdown = "# Notes\n\nRemember this sentence while reading.\n"
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        _ = try await bridge.call("toggleOutline")
        try await waitUntil {
            try await bridge.webView.callAsyncJavaScript(
                """
                const node=document.querySelector('.mdv-article p [data-reader-text]').firstChild;
                const range=document.createRange();range.setStart(node,0);range.setEnd(node,1);
                const r=range.getBoundingClientRect();
                return !!document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)?.closest('.mdv-article');
                """, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
        }
        let points =
            try await bridge.webView.callAsyncJavaScript(
                """
                const node=document.querySelector('.mdv-article p [data-reader-text]').firstChild;
                const point=offset=>{const range=document.createRange();range.setStart(node,offset);range.setEnd(node,offset+1);const r=range.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2};};
                window.waveProbe={node,element:node.parentElement,text:node.textContent};
                return [point(0),point(4),point(12)];
                """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Double]]
        let positions = try XCTUnwrap(points)
        func stroke(_ sequence: Int, phase: String, end: Int) async throws {
            _ = try await bridge.call(
                "annotationPencil",
                arguments: [
                    "payload": [
                        "id": "stable-pencil", "sequence": sequence, "phase": phase,
                        "start": positions[0], "point": positions[end],
                    ]
                ])
        }
        try await stroke(1, phase: "update", end: 1)
        let first =
            try await bridge.webView.evaluateJavaScript(
                """
                waveProbe.svg=document.querySelector('.jm-annotation-waves svg');
                waveProbe.path=waveProbe.svg?.querySelector('path');
                waveProbe.width=waveProbe.svg?.getBoundingClientRect().width;
                !!waveProbe.path && waveProbe.svg.getBoundingClientRect().height>0;
                """) as? Bool
        XCTAssertEqual(first, true)
        try await stroke(2, phase: "update", end: 2)
        let stable =
            try await bridge.webView.evaluateJavaScript(
                """
                waveProbe.node===waveProbe.element.firstChild && waveProbe.node.textContent===waveProbe.text &&
                waveProbe.svg===document.querySelector('.jm-annotation-waves svg') &&
                waveProbe.path===waveProbe.svg.querySelector('path') &&
                waveProbe.svg.getBoundingClientRect().width>waveProbe.width;
                """) as? Bool
        XCTAssertEqual(stable, true)
        try await stroke(3, phase: "commit", end: 2)
        try await waitUntil { session.annotations.visible.count == 1 }
        await session.waitForAnnotations()
        let adopted =
            try await bridge.webView.evaluateJavaScript(
                """
                ({sameNode:waveProbe.svg===document.querySelector('.jm-annotation-waves svg'),
                  connected:waveProbe.svg.isConnected,count:document.querySelectorAll('.jm-annotation-waves svg').length});
                """) as? [String: Any]
        XCTAssertEqual(adopted?["sameNode"] as? Bool, true, "\(String(describing: adopted))")
        XCTAssertEqual(adopted?["connected"] as? Bool, true)
        XCTAssertEqual(adopted?["count"] as? Int, 1)
        XCTAssertEqual(session.document?.text, markdown)
    }

    @MainActor
    func testAnnotationMappingPreservesHTMLEntitiesAndPartialTableCells() async throws {
        let markdown =
            "# Mapping\n\n<div><p>HTML &amp; 中文</p></div>\n\n| one | two |\n| --- | --- |\n| alpha | beta |\n"
        let (session, bridge, _) = try await navigationReader(markdown: markdown)
        _ = try await bridge.webView.callAsyncJavaScript(
            """
            const element=[...document.querySelectorAll('.mdv-article p')].find(e=>e.textContent==='HTML & 中文');
            const range=document.createRange();range.selectNodeContents(element);
            getSelection().removeAllRanges();getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
        try await waitUntil { session.annotations.visible.count == 1 }
        let html = (markdown as NSString).range(of: "HTML &amp; 中文")
        XCTAssertEqual(session.annotations.visible.first?.ranges, [.init(start: html.location, end: NSMaxRange(html))])
        _ = try await bridge.webView.callAsyncJavaScript(
            """
            const cells=[...document.querySelectorAll('.mdv-article td')],a=cells[0].querySelector('[data-reader-text]').firstChild,b=cells[1].querySelector('[data-reader-text]').firstChild;
            const range=document.createRange();range.setStart(a,2);range.setEnd(b,2);
            getSelection().removeAllRanges();getSelection().addRange(range);
            """, arguments: [:], in: nil, contentWorld: .page)
        _ = try await bridge.call("annotationSelectionAction", arguments: ["payload": ["action": "underline"]])
        try await waitUntil { session.annotations.visible.count == 2 }
        let alpha = (markdown as NSString).range(of: "alpha")
        let beta = (markdown as NSString).range(of: "beta")
        let expected = [
            AnnotationRange(start: alpha.location + 2, end: NSMaxRange(alpha)),
            .init(start: beta.location, end: beta.location + 2),
        ]
        XCTAssertTrue(session.annotations.visible.contains { $0.ranges == expected })
    }
}
