import UIKit
import XCTest

@MainActor
final class ReaderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // A following case must not inherit this app's unfinished presentation.
        addTeardownBlock { @MainActor in
            XCUIApplication().terminate()
        }
    }

    private func useComponentSynchronization() throws {
        let synchronization = try UIInteractionSynchronization()
        addTeardownBlock { @MainActor in
            defer { synchronization.restore() }
            XCUIApplication().terminate()
        }
    }

    private func record(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rotate(
        to orientation: UIDeviceOrientation, in app: XCUIApplication,
        viewport: XCUIElement? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        SimulatorOrientation.set(orientation, file: file, line: line)
        let expected = SimulatorOrientation.interfaceOrientation(for: orientation)
        let viewport = viewport ?? app.webViews.firstMatch
        // A square window or a 180-degree turn can retain its dimensions. Verify
        // the target application's interface instead of the driver's device value.
        let layout = NSPredicate { _, _ in
            (try? SimulatorOrientation.interfaceOrientation(of: app)) == expected
                && viewport.exists && !viewport.frame.isEmpty
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: layout, object: nil)], timeout: 8), .completed,
            "The app must reach interface orientation \(expected.rawValue); viewport \(viewport.frame)",
            file: file, line: line)
    }

    private func assertTextIsPainted(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line)
        throws
    {
        // Accessibility nodes survive a missing WebKit backing store. Check the
        // actual screen pixels so DOM presence alone cannot pass this regression.
        let image = try XCTUnwrap(element.screenshot().image.cgImage, file: file, line: line)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                file: file, line: line)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var brightness: [Int] = []
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            brightness.append((red + green + blue) / 3)
        }
        let background = brightness.sorted()[brightness.count / 2]
        XCTAssertGreaterThan(
            brightness.filter { abs($0 - background) > 40 }.count, 12,
            "The outline element exists but its text has not been painted", file: file, line: line)
    }

    private func allowDataSharingIfRequested(_ app: XCUIApplication) {
        let allow = app.alerts.buttons["AllowModelDataSharing"].firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    func testLocalImagePermissionSeparatesPathAndPresentsSystemPicker() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        editor.typeText(
            "\n\n![Permission figure](/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/Downloads/images/figure.svg)\n\n"
        )
        XCTAssertTrue((editor.value as? String)?.contains("Permission figure") == true)
        showTools(app)
        tapAfterTyping(app.buttons["ModeToggle"], in: app)
        let title = app.staticTexts["ResourcePermissionTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "需要加载本地图片")
        let explanation = app.staticTexts["ResourcePermissionExplanation"]
        let path = app.staticTexts["ResourcePermissionPath"]
        XCTAssertEqual(explanation.label, "文档引用了以下文件夹中的图片，请允许访问。")
        XCTAssertEqual(path.label, "iCloud 云盘 / Downloads / images")
        XCTAssertGreaterThanOrEqual(path.frame.minY, explanation.frame.maxY)
        XCTAssertTrue(app.buttons["CancelResourcePermission"].isHittable)
        let choose = app.buttons["ContinueResourcePermission"]
        XCTAssertTrue(choose.isHittable)
        record("local-image-permission")
        choose.tap()
        let open = app.navigationBars.buttons["打开"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        record("local-image-folder-picker")
        cancelFolderPicker(in: app)
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            title.waitForNonExistence(timeout: 5), "Cancelling the picker returns to reading without another prompt")
        let reading = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.buttons["ToolsToggle"].isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reading], timeout: 5), .completed)
    }

    func testLocalDocumentLinkOffersFolderAuthorizationAndCanBeCancelled() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        editor.typeText(
            "\n\n[Open linked chapter](/var/mobile/Library/Mobile%20Documents/com~apple~CloudDocs/Downloads/Lessons/chapter.md)\n\n"
        )
        showTools(app)
        tapAfterTyping(app.buttons["ModeToggle"], in: app)
        let link = app.webViews.links["Open linked chapter"]
        XCTAssertTrue(link.waitForExistence(timeout: 8))
        link.tap()
        let title = app.staticTexts["ResourcePermissionTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "打开本地文档")
        XCTAssertEqual(
            app.staticTexts["ResourcePermissionExplanation"].label, "文档位于以下文件夹，请允许访问。")
        XCTAssertEqual(app.staticTexts["ResourcePermissionPath"].label, "iCloud 云盘 / Downloads / Lessons")
        XCTAssertFalse(app.alerts.firstMatch.exists, "A local link needs actionable authorization rather than an error")
        record("local-document-permission")
        app.buttons["ContinueResourcePermission"].tap()
        let open = app.navigationBars.buttons["打开"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        record("local-document-folder-picker")
        cancelFolderPicker(in: app)
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5), "A cancelled link can request permission again")
        app.buttons["CancelResourcePermission"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(link.isHittable)
    }

    private func cancelFolderPicker(in app: XCUIApplication) {
        let cancel = app.navigationBars.buttons["取消"].firstMatch
        // The system picker can retain a nested directory. Its Cancel action
        // appears at the navigation root on compact devices.
        for _ in 0..<5 {
            if cancel.isHittable { break }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.isHittable)
            back.tap()
        }
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
    }

    func testDocumentTitleDoesNotOverlapCloseControlWithOutlineExpanded() throws {
        SimulatorOrientation.set(.portrait)
        defer { SimulatorOrientation.set(.portrait) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--sample-document", "--reset-sample-document"]
        app.launch()
        let outline = app.buttons["OutlineToggle"]
        XCTAssertTrue(outline.waitForExistence(timeout: 25))
        waitForEnabled(outline)
        let chapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        if !chapter.exists { outline.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(to: orientation, in: app)
            let laidOut = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.buttons["CloseDocument"].isHittable
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [laidOut], timeout: 8), .completed)
            let title = "Markdown 长文阅读与技术笔记"
            let outlineTitle = app.webViews.links[title]
            XCTAssertTrue(outlineTitle.exists)
            // WebKit may expose a text child for the outline link as well as the H1.
            let heading = try XCTUnwrap(
                app.webViews.staticTexts.matching(identifier: title).allElementsBoundByIndex.first {
                    let frame = $0.frame
                    return !frame.isEmpty && frame.intersects(app.webViews.firstMatch.frame)
                        && !outlineTitle.frame.contains(frame)
                })
            for control in ["OutlineToggle", "CloseDocument"] {
                XCTAssertFalse(
                    heading.frame.intersects(app.buttons[control].frame),
                    "The document title must remain outside the \(control) control's touch area")
            }
            record("document-title-clearance-\(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }

    func testFloatingToolsRemainInteractiveAfterCollapseAndRapidReversal() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--sample-document", "--reset-sample-document"]
        app.launch()
        let toggle = app.buttons["ToolsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            rotate(to: orientation, in: app)
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    toggle.isHittable
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
            XCTAssertFalse(app.buttons["More"].exists)
            let anchor = toggle.frame
            showTools(app)
            for id in ["GlobalAI", "ModeToggle", "More"] {
                let action = app.buttons[id]
                XCTAssertTrue(action.isHittable)
                XCTAssertGreaterThanOrEqual(action.frame.width, 44)
                XCTAssertGreaterThanOrEqual(action.frame.height, 44)
                XCTAssertEqual(action.frame.midY, anchor.midY, accuracy: 1)
                XCTAssertLessThan(action.frame.midX, toggle.frame.midX)
            }
            XCTAssertEqual(toggle.frame.midX, anchor.midX, accuracy: 1)
            XCTAssertEqual(toggle.frame.midY, anchor.midY, accuracy: 1)
            record("preview-tools-expanded-\(orientation.isLandscape ? "landscape" : "portrait")")
            if orientation == .portrait {
                for target in [UIDeviceOrientation.landscapeRight, .portrait] {
                    rotate(to: target, in: app)
                    let toolsFit = XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in
                            ["ToolsToggle", "GlobalAI", "ModeToggle", "More"].allSatisfy {
                                app.buttons[$0].isHittable
                            }
                        }, object: nil)
                    XCTAssertEqual(
                        XCTWaiter.wait(for: [toolsFit], timeout: 8), .completed,
                        "Rotation must preserve expanded tools after the target layout is ready")
                }
            }
            toggle.tap()
            XCTAssertTrue(app.buttons["More"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(toggle.frame.midX, anchor.midX, accuracy: 1)
        }
        SimulatorOrientation.set(.portrait)
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for cycle in 0..<3 {
            let anchor = toggle.frame
            showTools(app)
            XCTAssertTrue(app.buttons["GlobalAI"].isHittable)
            XCTAssertEqual(toggle.frame.midX, anchor.midX, accuracy: 1)
            XCTAssertEqual(toggle.frame.midY, anchor.midY, accuracy: 1)
            record("tools-expanded-cycle-\(cycle)")
            toggle.tap()
            guard app.buttons["GlobalAI"].waitForNonExistence(timeout: 5) else {
                record("tools-failed-to-collapse-cycle-\(cycle)")
                XCTFail("The expanded tools must actually disappear after collapsing")
                return
            }
            XCTAssertTrue(toggle.isHittable)
            toggle.doubleTap()
        }
        showTools(app)
        toggle.tap()
        XCTAssertTrue(app.buttons["ModeToggle"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(toggle.isHittable)
    }

    func testNativeSourceFillsViewportAndPreservesExpandedControlsDuringInput() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let web = app.webViews.firstMatch
        XCTAssertEqual(editor.frame.minX, web.frame.minX, accuracy: 1)
        XCTAssertEqual(editor.frame.maxX, web.frame.maxX, accuracy: 1)
        XCTAssertEqual(editor.frame.maxY, web.frame.maxY, accuracy: 1)
        XCTAssertEqual(editor.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        record("native-source-full-page")
        showTools(app)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["GlobalAI"].isHittable, "Focusing source must preserve expanded tools")
        editor.typeText("Native source input.\n")
        XCTAssertTrue(app.buttons["More"].isHittable, "Typing must not collapse the shared controls")
        app.buttons["ToolsToggle"].tap()
        XCTAssertTrue(app.buttons["GlobalAI"].waitForNonExistence(timeout: 5))
        record("native-source-keyboard-folded-tools")
        let inserted = editor.value as? String
        editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
        editor.tap()
        let foldedTools = app.buttons["ToolsToggle"].frame
        showTools(app)
        for id in ["ToolsToggle", "SourceUndo", "SourceRedo", "GlobalAI", "ModeToggle", "More"] {
            let action = app.buttons[id]
            XCTAssertTrue(action.exists, "Missing action: \(id)")
            XCTAssertEqual(action.frame.midY, foldedTools.midY, accuracy: 1, "Unfolding must preserve the anchor")
            XCTAssertFalse(action.frame.intersects(app.keyboards.firstMatch.frame))
        }
        app.buttons["SourceUndo"].tap()
        XCTAssertTrue(editor.value as? String == inserted, "Consecutive keyboard deletions undo together")
        showTools(app)
        XCTAssertTrue(app.buttons["SourceUndo"].isEnabled)
        XCTAssertGreaterThanOrEqual(app.buttons["SourceUndo"].frame.minX, 0)
        record("native-source-keyboard-expanded-tools")
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(
            app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Native source input."))
                .firstMatch.waitForExistence(timeout: 10))
    }

    func testCodeBlockCopyPastesPlainTextThroughTheSystemMenu() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        let code = "let copiedValue = 314159"
        editor.typeText("\n\n```swift\n\(code)\n```\n\n")
        showTools(app)
        tapAfterTyping(app.buttons["ModeToggle"], in: app)
        let copy = app.webViews.buttons["Copy Code"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        record("code-copy-feedback")
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let originalCount = (editor.value as? String ?? "").components(separatedBy: code).count
        XCTAssertEqual(originalCount, 2)
        editor.doubleTap()
        let paste = app.descendants(matching: .any).matching(identifier: "Paste").firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 6))
        paste.tap()
        let pasted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (editor.value as? String ?? "").components(separatedBy: code).count == originalCount + 1
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 8), .completed)
        XCTAssertFalse((editor.value as? String ?? "").contains("<svg"))
        record("copied-code-pasted-as-text")
    }

    func testSystemPasteMenuKeepsUndoAndRedoSeparateFromTyping() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-paste-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        editor.typeText("typedbeforepaste")
        let typed = editor.value as? String
        XCTAssertTrue(typed?.contains("typedbeforepaste") == true)
        editor.doubleTap()
        record("system-paste-menu-before-action")
        let paste = app.descendants(matching: .any).matching(identifier: "Paste").firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 6))
        paste.tap()
        let applied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Pasted **text**."), object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 8), .completed)
        let pasted = editor.value as? String
        showTools(app)
        app.buttons["SourceUndo"].tap()
        XCTAssertEqual(editor.value as? String, typed, "System paste must undo without removing earlier typing")
        app.buttons["SourceRedo"].tap()
        XCTAssertEqual(editor.value as? String, pasted, "Redo must restore the actual pasted content")
        record("system-paste-undone-and-redone")
    }

    func testNativeSourceEditingSurvivesRotation() {
        SimulatorOrientation.set(.portrait)
        defer { SimulatorOrientation.set(.portrait) }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        let web = app.webViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.14)).tap()
        editor.typeText("RotationProbe")
        var text = editor.value as? String
        for (orientation, name) in [
            (UIDeviceOrientation.landscapeLeft, "landscape-left"), (.landscapeRight, "landscape-right"),
            (.portrait, "portrait"),
        ] {
            rotate(to: orientation, in: app)
            let layout = NSPredicate { _, _ in
                let frame = editor.frame
                let viewport = web.frame
                let keyboard = app.keyboards.firstMatch
                let bottomFits =
                    abs(frame.maxY - viewport.maxY) < 1
                    // XCUI's keyboard frame excludes the input assistant bar.
                    // Native hosting tests assert the exact keyboard guide boundary.
                    || (keyboard.exists && frame.maxY <= keyboard.frame.minY + 1)
                return abs(frame.minX - viewport.minX) < 1 && abs(frame.maxX - viewport.maxX) < 1
                    && bottomFits && frame.height > 0
            }
            let settled = XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: layout, object: editor)], timeout: 8)
            record("native-source-layout-" + name)
            XCTAssertEqual(
                settled, .completed,
                "Rotated source \(editor.frame), viewport \(web.frame), app \(app.windows.firstMatch.frame), keyboard \(app.keyboards.firstMatch.frame)"
            )
            XCTAssertTrue(editor.value as? String == text, "Rotation must preserve the working text")
            XCTAssertTrue(app.buttons["ToolsToggle"].exists)
            XCTAssertFalse(app.buttons["GlobalAI"].exists)
            editor.typeText("x")
            XCTAssertEqual((editor.value as? String)?.utf16.count, (text?.utf16.count ?? 0) + 1)
            text = editor.value as? String
            record("native-source-input-" + name)
        }
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(
            app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "RotationProbe"))
                .firstMatch.waitForExistence(timeout: 10))
    }

    func testPrivacyPolicyHomeEntryAndLocalizedContent() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        for (language, locale, title, firstSection, lastSection) in [
            ("zh-Hans", "zh_CN", "隐私政策", "1. 适用范围", "9. 政策更新与联系"),
            ("en", "en_US", "Privacy Policy", "1. Scope", "9. Updates and contact"),
        ] {
            app.launchArguments = [
                "--ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            ]
            app.launch()
            let entry = app.buttons["PrivacyPolicy"]
            XCTAssertTrue(entry.waitForExistence(timeout: 8))
            let open = app.buttons["OpenDocument"]
            XCTAssertGreaterThanOrEqual(entry.frame.width, 44)
            XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
            XCTAssertGreaterThan(entry.frame.minY, open.frame.maxY)
            XCTAssertGreaterThan(entry.frame.midX, app.windows.firstMatch.frame.midX)
            let version = app.staticTexts["AppVersion"]
            XCTAssertTrue(version.exists)
            XCTAssertGreaterThanOrEqual(version.frame.minY, entry.frame.maxY - 0.5)
            XCTAssertEqual(version.frame.maxX, entry.frame.maxX, accuracy: 1)
            XCTAssertTrue(version.label.hasPrefix(language == "zh-Hans" ? "版本 " : "Version "))
            record("home-privacy-\(language)")
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            let policy = app.scrollViews["PrivacyPolicyContent"]
            XCTAssertTrue(policy.staticTexts[firstSection].waitForExistence(timeout: 8))
            XCTAssertFalse(open.isHittable)
            XCTAssertTrue(
                policy.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "lichenxi.catapple@gmail.com"))
                    .firstMatch.exists)
            record("privacy-policy-\(language)")
            let last = policy.staticTexts[lastSection]
            for _ in 0..<20 {
                if last.isHittable { break }
                policy.swipeUp()
            }
            XCTAssertTrue(last.isHittable, "The complete policy must be readable inside the modal")
            record("privacy-policy-bottom-\(language)")
            app.buttons["ClosePrivacyPolicy"].tap()
            XCTAssertTrue(open.waitForExistence(timeout: 5))
            XCTAssertTrue(entry.isHittable)
            app.terminate()
        }
    }

    func testSendingConsentCancelAllowAndPersistence() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        for (language, locale, title, send, allow, cancel) in [
            ("zh-Hans", "zh_CN", "允许发送到此 AI 服务？", "发送问题", "允许", "取消"),
            ("en", "en_US", "Allow Sending to This AI Service?", "Send message", "Allow", "Cancel"),
        ] {
            app.launchArguments = [
                "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
                "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
            ]
            app.launch()
            XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
            showTools(app)
            app.buttons["GlobalAI"].tap()
            let input = app.textViews["QuestionInput"]
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            XCTAssertEqual(app.buttons["SendAgentMessage"].label, send)
            XCTAssertFalse(app.alerts[title].exists, "Opening AI must not ask for sending permission")
            input.tap()
            input.typeText("Explain Markdown.")
            tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
            let alert = app.alerts[title]
            XCTAssertTrue(alert.waitForExistence(timeout: 6))
            XCTAssertEqual(alert.buttons["AllowModelDataSharing"].firstMatch.label, allow)
            XCTAssertEqual(alert.buttons["CancelModelDataSharing"].firstMatch.label, cancel)
            XCTAssertTrue(
                alert.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS %@", "https://ui-fixture.markdownit.invalid/v1")
                ).firstMatch.exists)
            record("ai-sending-consent-\(language)")
            alert.buttons["CancelModelDataSharing"].firstMatch.tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, "Explain Markdown.")
            waitForEnabled(app.buttons["SendAgentMessage"])
            app.buttons["SendAgentMessage"].tap()
            XCTAssertTrue(alert.waitForExistence(timeout: 6), "Cancel must not store permission")
            alert.buttons["AllowModelDataSharing"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
            XCTAssertEqual(input.value as? String, "")

            app.terminate()
            app.launchArguments.removeAll { ["--sample-document", "--reset-sample-document"].contains($0) }
            app.launchArguments.append("--ui-test-keep-state")
            app.launch()
            XCTAssertTrue(input.waitForExistence(timeout: 25), "Relaunch must restore the open AI panel")
            XCTAssertEqual(input.value as? String, "")
            let replies = app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "通过目录导航"))
            XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 25))
            XCTAssertEqual(replies.count, 1, "The existing conversation must survive relaunch")
            record("ai-conversation-restored-\(language)")
            app.buttons["CollapseAgent"].tap()
            XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
            showTools(app)
            app.buttons["GlobalAI"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.tap()
            input.typeText("Explain Markdown again.")
            tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [
                        XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in replies.count == 2 }, object: nil)
                    ], timeout: 12), .completed,
                "A new answer must complete without asking for the service's permission again")
            XCTAssertFalse(alert.exists, "The same service must remain authorized after relaunch")
            app.terminate()
        }
    }

    func testEnglishInterfaceAcrossReaderSettingsAndRecents() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        let outline = app.buttons["OutlineToggle"]
        let firstChapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        if !firstChapter.exists { outline.tap() }
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 8))
        XCTAssertEqual(outline.label, "Hide contents")
        record("english-reader-preview")
        outline.tap()

        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.alerts["AI Model Not Configured"].waitForExistence(timeout: 5))
        app.alerts.buttons["Open Settings"].tap()
        XCTAssertTrue(app.navigationBars["Model Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["API Type"].exists)
        app.buttons["ModelPicker"].tap()
        XCTAssertTrue(app.buttons["CustomModelEntry"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["CustomModelEntry"].label, "Custom…")
        app.buttons["CustomModelEntry"].tap()
        XCTAssertTrue(app.textFields["ModelID"].waitForExistence(timeout: 5))
        record("english-model-settings")
        app.buttons["Cancel"].tap()

        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertTrue((editor.value as? String ?? "").hasPrefix("# Markdown 长文阅读与技术笔记"))
        showTools(app)
        XCTAssertEqual(app.buttons["SourceUndo"].label, "Undo")
        XCTAssertEqual(app.buttons["SourceRedo"].label, "Redo")
        app.buttons["CloseDocument"].tap()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertEqual(open.label, "Open Document")
        XCTAssertEqual(app.buttons["RecentDocuments"].label, "Recent Documents...")
        app.buttons["RecentDocuments"].tap()
        XCTAssertTrue(app.navigationBars["Recent Documents"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RecentDocument-")).firstMatch
        XCTAssertEqual(row.label, "reading-guide.md")
    }

    func testEnglishAgentUsesLocalizedControls() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertEqual(input.label, "AI message")
        XCTAssertTrue(app.buttons["CollapseAgent"].exists)
        let title = app.staticTexts["ConversationTitle"]
        XCTAssertEqual(title.label, "AI Conversation")
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.buttons["ClearAgentHistory"].frame.maxX)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.buttons["CollapseAgent"].frame.minX)
        XCTAssertEqual(title.frame.midY, app.buttons["CollapseAgent"].frame.midY, accuracy: 1)
        XCTAssertFalse(app.webViews.buttons["Remove reference"].exists)
        XCTAssertEqual(app.buttons["SendAgentMessage"].label, "Send message")
        XCTAssertFalse(app.webViews.buttons["Expand reference"].exists)
        for id in ["ToolsToggle", "GlobalAI", "ModeToggle", "More"] {
            XCTAssertFalse(app.buttons[id].exists, "AI hides the complete bottom group on every layout")
        }
        record("english-agent")
        app.buttons["CollapseAgent"].tap()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["More"].exists, "The restored group starts collapsed")
    }

    func testUnsupportedSystemLanguageFallsBackToEnglish() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertEqual(open.label, "Open Document")
        app.buttons["RecentDocuments"].tap()
        let empty = app.staticTexts["RecentDocumentsEmpty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(empty.label, "No recent documents")
    }

    func testModelSettingsMenuReopensAfterSourceEditing() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        showTools(app)
        let mode = app.buttons["ModeToggle"]
        mode.tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        editor.tap()
        typeSource("menu check", into: editor)
        for marker in ["settings return one", "settings return two"] {
            showTools(app)
            app.buttons["More"].tap()
            app.buttons["模型设置"].tap()
            let baseURL = app.textFields["ModelBaseURL"]
            XCTAssertTrue(baseURL.waitForExistence(timeout: 5))
            baseURL.tap()
            app.buttons["取消"].tap()
            editor.tap()
            typeSource("\n" + marker, into: editor)
            XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
        }
        showTools(app)
        mode.tap()

        for _ in 0..<3 {
            showTools(app)
            app.buttons["More"].tap()
            app.buttons["模型设置"].tap()
            XCTAssertTrue(app.textFields["ModelBaseURL"].waitForExistence(timeout: 5))
            app.buttons["取消"].tap()
        }
    }

    func testReaderNavigationEditingSettingsAndRotation() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let mode = app.buttons["ModeToggle"]
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25) || mode.exists)
        if app.buttons["ToolsToggle"].exists {
            XCTAssertFalse(mode.exists, "Collapsed tools must leave the accessibility tree")
            record("phone-tools-collapsed")
        }
        showTools(app)
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        let heading = app.webViews.staticTexts["Markdown 长文阅读与技术笔记"]
        XCTAssertTrue(heading.waitForExistence(timeout: 25))
        let originalModeFrame = mode.frame
        XCTAssertLessThan(app.buttons["GlobalAI"].frame.midX, mode.frame.midX)
        XCTAssertLessThan(mode.frame.midX, app.buttons["More"].frame.midX)
        XCTAssertLessThanOrEqual(app.buttons["More"].frame.maxX, app.windows.firstMatch.frame.width)
        let outline = app.buttons["OutlineToggle"]
        let outlineFrame = outline.frame
        let firstChapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        if firstChapter.exists { outline.tap() }
        outline.tap()
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 5))
        XCTAssertEqual(outline.frame.origin.x, outlineFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(outline.frame.origin.y, outlineFrame.origin.y, accuracy: 0.5)
        record("outline-portrait")
        firstChapter.tap()
        if firstChapter.exists { outline.tap() }
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "切换到预览"), object: mode)],
                timeout: 5), .completed)
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(mode.frame.origin.x, originalModeFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(mode.frame.origin.y, originalModeFrame.origin.y, accuracy: 0.5)
        record("source-portrait")
        editor.tap()
        typeSource("\n\n## Native UI verification\n\nSaved from the source view.\n\n", into: editor)
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertTrue(outline.waitForExistence(timeout: 8))
        outline.tap()
        XCTAssertTrue(app.webViews.links["Native UI verification"].waitForExistence(timeout: 8))
        outline.tap()

        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        XCTAssertFalse(mode.isHittable, "Settings must block the document controls")
        mode.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(mode.label, "切换到源码模式")
        base.tap()
        base.typeText("https://example.test/v1")
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let custom = app.buttons["自定义…"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertTrue(custom.isHittable)
        custom.tap()
        let model = app.textFields["ModelID"]
        model.tap()
        model.typeText("test-model")
        let key = app.secureTextFields["ModelAPIKey"]
        tapAfterTyping(key, in: app)
        key.typeText("ui-test-only-key")
        record("model-settings")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 5) || mode.exists)
        record("after-settings-dismissal")
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label == %@", "切换到预览"), object: mode)
                ],
                timeout: 8),
            .completed, "Mode switching must work after the dismissal transition")
        showTools(app)
        mode.tap()
        showTools(app)
        XCTAssertTrue(outline.waitForExistence(timeout: 8))

        SimulatorOrientation.set(.landscapeLeft)
        XCTAssertTrue(outline.waitForExistence(timeout: 5))
        outline.tap()
        record("outline-landscape")
        XCTAssertEqual(outline.label, "收起文章目录")
        XCTAssertGreaterThanOrEqual(outline.frame.width, 44)
        XCTAssertGreaterThanOrEqual(outline.frame.height, 44)
        outline.tap()
        record("reader-landscape")
        SimulatorOrientation.set(.portrait)
    }

    func testModelSettingsRestoresCompleteConnectionAndResetIsExplicit() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        let arguments = ["--ui-testing", "--sample-document", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchArguments = arguments + ["--reset-sample-document", "--ui-test-agent-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        func openSettings() {
            showTools(app)
            app.buttons["More"].tap()
            app.buttons["模型设置"].tap()
            XCTAssertTrue(app.textFields["ModelBaseURL"].waitForExistence(timeout: 6))
        }
        openSettings()
        app.buttons["ModelPicker"].tap()
        let choice = app.buttons["ModelChoice.catalog-only-model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 6))
        choice.tap()
        app.buttons["SettingsDone"].tap()
        app.terminate()
        app.launchArguments = arguments + ["--ui-test-keep-state"]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.textViews["QuestionInput"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.alerts["尚未配置 AI 模型"].exists)
        app.buttons["CollapseAgent"].tap()
        openSettings()
        let base = app.textFields["ModelBaseURL"]
        let key = app.secureTextFields["ModelAPIKey"]
        XCTAssertEqual(base.value as? String, "https://ui-fixture.markdownit.invalid/v1")
        XCTAssertEqual(app.buttons["ModelPicker"].value as? String, "catalog-only-model")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        record("model-settings-reset-action")

        app.buttons["ResetModelSettings"].tap()
        let confirmation = app.alerts["重置模型设置？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts["已保存的连接信息和所有 API Key 都将被移除。"].exists)
        record("model-settings-reset-confirmation")
        confirmation.buttons["取消"].tap()
        XCTAssertEqual(base.value as? String, "https://ui-fixture.markdownit.invalid/v1")
        XCTAssertEqual(app.buttons["ModelPicker"].value as? String, "catalog-only-model")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)

        app.buttons["ResetModelSettings"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["重置"].tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue((key.value as? String ?? "").isEmpty)
        XCTAssertEqual(app.buttons["ModelPicker"].value as? String, "")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        record("model-settings-reset-complete")
        // Reset is committed immediately; dismissing the form cannot resurrect it.
        app.buttons["取消"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.alerts["尚未配置 AI 模型"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.alerts["尚未配置 AI 模型"].waitForExistence(timeout: 5))
        record("model-settings-reset-persists-after-relaunch")
    }

    func testModelSettingsShowsFieldSpecificAlertsAndPreservesTheDraft() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        let base = app.textFields["ModelBaseURL"]
        let key = app.secureTextFields["ModelAPIKey"]
        let url = "http://127.0.0.1:1/v1"
        base.tap()
        base.typeText(url)
        tapAfterTyping(key, in: app)
        key.typeText("ui-test-only-key")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        let missingModel = app.alerts["请选择模型。"]
        XCTAssertTrue(missingModel.waitForExistence(timeout: 5))
        XCTAssertEqual(missingModel.buttons.count, 1)
        record("model-settings-missing-model")
        missingModel.buttons["好"].tap()
        XCTAssertTrue(missingModel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(base.value as? String, url)
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        XCTAssertEqual(picker.value as? String, "")

        picker.tap()
        let customEntry = app.buttons["CustomModelEntry"]
        XCTAssertTrue(customEntry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["保存密码？"].exists)
        customEntry.tap()
        let model = app.textFields["ModelID"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        app.buttons["SettingsDone"].tap()
        let missingID = app.alerts["请输入模型 ID。"]
        XCTAssertTrue(missingID.waitForExistence(timeout: 5))
        missingID.buttons["好"].tap()
        XCTAssertTrue(missingID.waitForNonExistence(timeout: 5))
        XCTAssertEqual(base.value as? String, url)
        model.tap()
        model.typeText("ui-test-model")

        waitForVisibleSoftwareKeyboard(in: app)
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (base.value as? String ?? "").count))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Editing must not present validation alerts")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        let missingURL = app.alerts["请输入 Base URL。"]
        XCTAssertTrue(missingURL.waitForExistence(timeout: 5))
        missingURL.buttons["好"].tap()
        XCTAssertTrue(missingURL.waitForNonExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "ui-test-model")
        base.tap()
        base.typeText("not-a-url")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        let invalidURL = app.alerts["Base URL 格式不正确。"]
        XCTAssertTrue(invalidURL.waitForExistence(timeout: 5))
        record("model-settings-invalid-url")
        invalidURL.buttons["好"].tap()
        XCTAssertTrue(invalidURL.waitForNonExistence(timeout: 5))
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "not-a-url".count))
        base.typeText(url)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        record("model-settings-validation-corrected")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        XCTAssertTrue(base.waitForNonExistence(timeout: 5))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        XCTAssertTrue(base.waitForExistence(timeout: 6))
        XCTAssertEqual(base.value as? String, url)
        XCTAssertEqual(picker.value as? String, "ui-test-model")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        XCTAssertTrue(app.staticTexts["连接信息将会仅保存在本机钥匙串。"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        record("model-settings-connection-footer")
    }

    func testNewDocumentCreatesLocalMarkdownAndStartsEditing() throws {
        // Closing the focused editor can leave XCTest waiting on a stale animation-idle notification.
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        let name = "Reading note " + UUID().uuidString.prefix(8)
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let create = app.buttons["NewDocument"]
        XCTAssertTrue(create.waitForExistence(timeout: 25))
        record("home-with-new-document")
        create.tap()
        let filename = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filename.waitForExistence(timeout: 8))
        record("new-document-save-dialog")
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable { cancel.tap() } else { app.navigationBars.firstMatch.swipeDown() }
        XCTAssertTrue(filename.waitForNonExistence(timeout: 8))
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        waitForEnabled(create)
        XCTAssertTrue(create.isHittable)
        XCTAssertFalse(app.textViews["SourceEditor"].exists)
        create.tap()
        XCTAssertTrue(filename.waitForExistence(timeout: 8))
        filename.tap()
        filename.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: (filename.value as? String ?? "").count))
        filename.typeText(name + "\n")
        XCTAssertEqual(filename.value as? String, name)
        record("new-document-named")
        // This system button has no identifier on iOS 26; the fixture pins its language to English.
        let save = app.buttons["Save"]
        XCTAssertTrue(save.isHittable)
        save.tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 12))
        XCTAssertEqual(editor.value as? String, "")
        record("new-document-empty-source")
        let content = "A newly created Markdown document."
        editor.typeText(content)
        XCTAssertEqual(editor.value as? String, content)
        app.buttons["CloseDocument"].tap()
        XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        app.buttons["RecentDocuments"].tap()
        let recent = app.staticTexts[name + ".md"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        XCTAssertTrue(app.webViews.staticTexts[content].waitForExistence(timeout: 12))
    }

    func testModelSelectionLoadsProviderChoicesAndKeepsCustomEntryAfterFailure() throws {
        try useComponentSynchronization()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertFalse(app.textFields["ModelID"].exists)
        picker.tap()
        let choice = app.buttons["ModelChoice.catalog-only-model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["自定义…"].exists)
        choice.tap()
        XCTAssertEqual(picker.value as? String, "catalog-only-model")
        app.buttons["SettingsDone"].tap()
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertEqual(picker.value as? String, "catalog-only-model")
        let base = app.textFields["ModelBaseURL"]
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (base.value as? String ?? "").count))
        base.typeText("https://ui-fixture.markdownit.invalid/unavailable/v1")
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        picker.tap()
        XCTAssertTrue(app.staticTexts["无法获取模型列表"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        app.buttons["自定义…"].tap()
        let custom = app.textFields["ModelID"]
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        XCTAssertEqual(custom.value as? String, "catalog-only-model")
        custom.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        custom.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "catalog-only-model".count))
        custom.typeText("my-custom-model")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        XCTAssertEqual(picker.value as? String, "my-custom-model")
        record("model-selection-custom-saved")
    }

    func testModelSelectionSearchesNamesAndIDsAndKeepsCurrentChoiceFirst() throws {
        try useComponentSynchronization()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 6))
        picker.tap()
        let current = app.buttons["ModelChoice.ui-test-model"]
        let choice = app.buttons["ModelChoice.catalog-only-model"]
        XCTAssertTrue(choice.waitForExistence(timeout: 8))
        XCTAssertLessThan(current.frame.minY, choice.frame.minY)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("CATALOG CHOICE")
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertTrue(current.exists)
        XCTAssertFalse(app.buttons["ModelChoice.provider/advanced-model"].exists)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "CATALOG CHOICE".count))
        search.typeText("advanced-model")
        let advanced = app.buttons["ModelChoice.provider/advanced-model"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertFalse(choice.exists)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        record("model-selection-search")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "advanced-model".count))
        search.typeText("gpt6.1")
        XCTAssertTrue(app.buttons["ModelChoice.openai/gpt-6.1-sol"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ModelChoice.provider/compact-name"].exists)
        XCTAssertFalse(advanced.exists)
        XCTAssertTrue(current.exists)
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        record("model-selection-compact-search")
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "gpt6.1".count))
        search.typeText("gpt61")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "gpt61".count))
        search.typeText("no-such-model")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["CustomModelEntry"].isHittable)
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "no-such-model".count))
        search.typeText("advancedmodel")
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        advanced.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "provider/advanced-model")
        XCTAssertFalse(app.textFields["ModelID"].exists)
        picker.tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertLessThan(advanced.frame.minY, choice.frame.minY, "Reopening must pin the newly selected model")
        advanced.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "provider/advanced-model")
        picker.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no-such-model")
        XCTAssertTrue(app.staticTexts["无匹配模型"].waitForExistence(timeout: 5))
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        app.buttons["CustomModelEntry"].tap()
        let customInput = app.textFields["ModelID"]
        XCTAssertTrue(customInput.waitForExistence(timeout: 5))
        customInput.typeText("-custom")
        XCTAssertEqual(customInput.value as? String, "provider/advanced-model-custom")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
    }

    func testModelSelectionAllowsCustomInputWhileCatalogIsLoading() throws {
        try useComponentSynchronization()
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-agent-fixture",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 6))
        base.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        base.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (base.value as? String ?? "").count))
        base.typeText("https://ui-fixture.markdownit.invalid/slow/v1")
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        app.buttons["ModelPicker"].tap()
        let loading = app.descendants(matching: .any).matching(identifier: "ModelListLoading").firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 4))
        let custom = app.buttons["CustomModelEntry"]
        XCTAssertTrue(custom.isHittable)
        custom.tap()
        let input = app.textFields["ModelID"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "ui-test-model")
        input.typeText("-custom")
        record("model-selection-loading-custom")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        showTools(app)
        app.buttons["More"].tap()
        app.buttons["模型设置"].tap()
        let picker = app.buttons["ModelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "ui-test-model-custom")
    }

    func testWelcomePresentsNativeFilePicker() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        record("welcome")
        open.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
        record("native-file-picker")
    }

    func testRecentDocumentsEmptyStateAndSecondaryPlacement() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let recent = app.buttons["RecentDocuments"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        let open = app.buttons["OpenDocument"]
        let create = app.buttons["NewDocument"]
        func assertActionPlacement() {
            XCTAssertEqual(recent.label, "最近打开...")
            XCTAssertGreaterThanOrEqual(recent.frame.height, 44)
            XCTAssertTrue(create.exists)
            XCTAssertEqual(open.frame.midY, create.frame.midY, accuracy: 1)
            XCTAssertEqual(open.frame.width, create.frame.width, accuracy: 1)
            XCTAssertEqual(open.frame.height, create.frame.height, accuracy: 1)
            let actions = open.frame.union(create.frame)
            XCTAssertGreaterThan(recent.frame.minY, actions.maxY)
            XCTAssertEqual(recent.frame.midX, actions.midX, accuracy: 1)
        }
        assertActionPlacement()
        record("home-recent-secondary-action")
        if UIDevice.current.userInterfaceIdiom == .pad {
            rotate(to: .landscapeLeft, in: app, viewport: open)
            assertActionPlacement()
            record("home-document-actions-landscape")
        }
        recent.tap()
        let empty = app.staticTexts["RecentDocumentsEmpty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        record("recent-documents-empty")
        let close = app.buttons["CloseRecentDocuments"]
        if close.exists {
            close.tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).tap()
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: empty)],
                timeout: 5), .completed)
    }

    func testRecentDocumentsSurviveRelaunchAndOpenInPlace() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let title = app.webViews.staticTexts["Markdown 长文阅读与技术笔记"]
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        app.buttons["CloseDocument"].tap()
        let recent = app.buttons["RecentDocuments"]
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "RecentDocument-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "reading-guide.md")
        record("recent-documents-list")
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        app.buttons["CloseDocument"].tap()
        app.terminate()
        app.launchArguments = [
            "--ui-testing", "--ui-test-keep-state", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(recent.waitForExistence(timeout: 8))
        recent.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "reading-guide.md")
        record("recent-documents-after-relaunch")
        row.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 25))
        XCTAssertFalse(app.buttons["CloseRecentDocuments"].exists)
    }

    func testCloseFromSourceReturnsHomeAndOpensAnotherDocumentPicker() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        let close = app.buttons["CloseDocument"]
        XCTAssertTrue(close.exists)
        XCTAssertEqual(close.frame.midY, app.buttons["OutlineToggle"].frame.midY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        record("reader-native-liquid-glass-close")
        showTools(app)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["模型设置"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["打开文档"].exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        editor.typeText("\n\nSaved by closing the document.\n")
        tapAfterTyping(close, in: app)
        let open = app.buttons["OpenDocument"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        XCTAssertFalse(close.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        record("closed-document-home")
        open.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 8))
    }

    func testFailedCloseOffersRetryDiscardAndCancel() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "--ui-test-save-failure",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Save recovery"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 6))
        editor.tap()
        typeSource("Close check.", into: editor)
        // Persistent write failure also affects autosave. Handle that error before
        // testing the separate close/retry/discard flow, regardless of runner speed.
        let autosaveAlert = app.alerts["无法完成操作"]
        XCTAssertTrue(autosaveAlert.waitForExistence(timeout: 8))
        autosaveAlert.buttons["好"].tap()
        app.buttons["CloseDocument"].tap()
        let alert = app.alerts["未能保存文档"]
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.buttons["重试"].exists)
        XCTAssertTrue(alert.buttons["放弃修改并关闭"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
        record("close-save-failed-native-alert")
        alert.buttons["重试"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["取消"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains("Close check.") == true)
        app.buttons["CloseDocument"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        alert.buttons["放弃修改并关闭"].tap()
        XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        record("discarded-document-home")
    }

    func testOutlineCentersChapterAndFollowsFastReading() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let outline = app.buttons["OutlineToggle"]
        XCTAssertTrue(outline.waitForExistence(timeout: 25))
        waitForEnabled(outline)
        let chapter = app.webViews.links["10. 连续阅读与位置检查"]
        if !chapter.exists { outline.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        chapter.tap()
        if !chapter.exists { outline.tap() }
        let centered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                abs(chapter.frame.midY - app.windows.firstMatch.frame.midY) < app.windows.firstMatch.frame.height * 0.15
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        record("outline-chapter-10-centered")
        if chapter.exists { outline.tap() }
        let lower = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.82))
        let upper = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.28))
        lower.press(forDuration: 0.01, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
        upper.press(forDuration: 0.01, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        outline.tap()
        record("outline-after-fast-reading-and-reversal")
    }

    func testBackgroundWindowSnapshotsPreserveLongDocumentRendering() throws {
        SimulatorOrientation.set(.landscapeLeft)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let toggle = app.buttons["OutlineToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        waitForEnabled(toggle)
        XCTAssertEqual(app.webViews.firstMatch.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        let chapter = app.webViews.links["10. 连续阅读与位置检查"]
        if !chapter.exists { toggle.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        chapter.tap()
        if !chapter.exists { toggle.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        try assertTextIsPainted(chapter)
        record("long-document-before-background")

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        for index in 1...3 {
            settings.activate()
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 8))
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))
            XCTAssertTrue(chapter.waitForExistence(timeout: 8))
            try assertTextIsPainted(chapter)
            record("long-document-after-background-\(index)")
        }
    }

    func testProcessRelaunchRestoresSourceAndHistoryUntilExplicitClose() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        let language = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = ["--ui-testing", "--sample-document", "--reset-sample-document"] + language
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        let original = editor.value as? String
        editor.tap()
        editor.typeText("Recoverededit")
        let edited = editor.value as? String
        XCTAssertNotEqual(edited, original)
        showTools(app)
        app.buttons["SourceUndo"].tap()
        XCTAssertEqual(editor.value as? String, original)
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-test-keep-state"] + language
        app.launch()
        XCTAssertTrue(
            editor.waitForExistence(timeout: 25), "Relaunch must restore source rather than showing the homepage")
        XCTAssertEqual(editor.value as? String, original)
        showTools(app)
        XCTAssertTrue(app.buttons["SourceRedo"].isEnabled)
        app.buttons["SourceRedo"].tap()
        XCTAssertEqual(editor.value as? String, edited)
        record("recovered-source-history")
        app.buttons["CloseDocument"].tap()
        XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        XCTAssertFalse(editor.exists)
    }

    func testTouchUndoRedoAndNewEditingBranch() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25) || app.buttons["ModeToggle"].exists)
        showTools(app)
        XCTAssertFalse(app.buttons["SourceUndo"].exists)
        app.buttons["ModeToggle"].tap()
        let editor = app.textViews["SourceEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        showTools(app)
        XCTAssertFalse(app.buttons["SourceUndo"].isEnabled)
        XCTAssertFalse(app.buttons["SourceRedo"].isEnabled)
        let original = editor.value as? String
        editor.tap()
        editor.typeText("undo-check ")
        showTools(app)
        let undo = app.buttons["SourceUndo"]
        let redo = app.buttons["SourceRedo"]
        XCTAssertTrue(undo.isEnabled)
        XCTAssertGreaterThanOrEqual(undo.frame.width, 44)
        XCTAssertLessThan(undo.frame.midX, redo.frame.midX)
        XCTAssertLessThan(redo.frame.midX, app.buttons["GlobalAI"].frame.midX)
        XCTAssertGreaterThanOrEqual(undo.frame.minX, 0)
        let edited = editor.value as? String
        XCTAssertNotEqual(edited, original)
        record("touch-source-history-with-keyboard")
        undo.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", original ?? ""), object: editor)
                ], timeout: 5), .completed)
        XCTAssertTrue(redo.isEnabled)
        record("touch-source-undone")
        redo.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", edited ?? ""), object: editor)
                ], timeout: 5), .completed)
        record("touch-source-redone")
        undo.tap()
        editor.tap()
        editor.typeText("new-branch ")
        showTools(app)
        XCTAssertFalse(redo.isEnabled)
    }

    func testUnifiedAIReadingEditingAndTouchHistory() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("请修改第一段，让它更简洁。")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        allowDataSharingIfRequested(app)
        XCTAssertTrue(app.webViews.staticTexts["请切换到源码模式后再修改。"].waitForExistence(timeout: 12))
        record("ai-preview-read-only")
        app.buttons["CollapseAgent"].tap()
        showTools(app)
        app.buttons["ModeToggle"].tap()
        XCTAssertTrue(app.textViews["SourceEditor"].waitForExistence(timeout: 8))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        input.tap()
        input.typeText("解释这份文档。")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        XCTAssertTrue(app.webViews.staticTexts["通过目录导航"].waitForExistence(timeout: 12))
        let answerEnd = app.webViews.staticTexts["保留原有格式"]
        let visibleAnswer = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in answerEnd.isHittable }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [visibleAnswer], timeout: 8), .completed,
            "The latest answer must follow into view without a manual scroll")
        record("ai-source-reading")
        let viewport = app.otherElements["ConversationPanel"]
        let send = app.buttons["SendAgentMessage"]
        // Rotation can switch between sheet and side presentations. Their outer
        // margins differ, but the native input must stay beside its send control.
        let inputSendGap = send.frame.minX - input.frame.maxX
        for (orientation, name) in [
            (UIDeviceOrientation.landscapeLeft, "landscape"), (.portrait, "portrait"),
        ] {
            rotate(to: orientation, in: app)
            // Interface orientation can change before the native input's frame.
            // Resolve the completed layout before synthesizing the next touch.
            let layout = NSPredicate { _, _ in
                let frame = input.frame
                let viewportFrame = viewport.frame
                let sendFrame = send.frame
                return abs(sendFrame.minX - frame.maxX - inputSendGap) < 1
                    && frame.width > 0 && frame.height > 0 && viewportFrame.contains(frame)
                    && viewportFrame.contains(sendFrame) && input.isHittable && send.isHittable
            }
            record("ai-source-reading-" + name)
            XCTAssertEqual(
                XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: layout, object: input)], timeout: 8),
                .completed,
                "Rotated input \(input.frame), send \(send.frame), viewport \(viewport.frame), "
                    + "expected input/send gap \(inputSendGap), hittable \(input.isHittable)/\(send.isHittable)"
            )
        }
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        input.typeText("请修改第一段，让它更简洁。")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        XCTAssertTrue(app.webViews.staticTexts["已修改这句话，其余内容保持原样。"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.webViews.buttons["撤销这次修改"].exists)
        record("ai-source-edit-applied")
        app.buttons["CollapseAgent"].tap()
        showTools(app)
        app.buttons["SourceUndo"].tap()
        XCTAssertTrue(app.buttons["SourceRedo"].isEnabled)
        record("ai-source-edit-undone")
        app.buttons["SourceRedo"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(app.webViews.buttons["撤销这次修改"].waitForExistence(timeout: 6))
        record("ai-source-edit-redone")
    }

    func testAdaptiveConversationKeepsDirectoryReachableAndDraftAcrossPanelSwitches() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        let outline = app.buttons["OutlineToggle"]
        XCTAssertTrue(outline.waitForExistence(timeout: 25))
        waitForEnabled(outline)
        let firstChapter = app.webViews.links["1. 从纯文本到可阅读的文档"]
        if firstChapter.exists { outline.tap() }
        let close = app.buttons["CloseDocument"]
        let trailingClose = close.frame
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        let draft = "哈哈哈，Hello"
        input.typeText(draft)
        XCTAssertEqual(input.value as? String, draft)
        record("adaptive-conversation-portrait-keyboard")
        XCTAssertTrue(outline.isHittable, "The directory entry must remain reachable while AI is open")
        if input.frame.minX > app.windows.firstMatch.frame.midX {
            func assertCloseAtLeading(file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertTrue(close.isHittable, file: file, line: line)
                if firstChapter.exists {
                    XCTAssertGreaterThan(close.frame.minX, firstChapter.frame.maxX, file: file, line: line)
                } else {
                    XCTAssertEqual(close.frame.minX, outline.frame.maxX + 32, accuracy: 1, file: file, line: line)
                }
                XCTAssertEqual(close.frame.midY, outline.frame.midY, accuracy: 0.5, file: file, line: line)
                XCTAssertEqual(
                    close.frame.midY, app.buttons["CollapseAgent"].frame.midY,
                    accuracy: 1, file: file, line: line)
                XCTAssertEqual(close.frame.size, trailingClose.size, file: file, line: line)
            }
            assertCloseAtLeading()
            record("adaptive-document-close-leading")
            XCTAssertGreaterThan(
                input.frame.minX, app.windows.firstMatch.frame.width / 2,
                "A side conversation must leave the document column visible")
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                rotate(to: orientation, in: app)
                XCTAssertEqual(
                    XCTWaiter.wait(
                        for: [
                            XCTNSPredicateExpectation(
                                predicate: NSPredicate { _, _ in
                                    input.frame.minX > app.windows.firstMatch.frame.width / 2
                                        && input.value as? String == draft
                                }, object: nil)
                        ], timeout: 8), .completed)
            }
            assertCloseAtLeading()
            outline.tap()
            XCTAssertTrue(firstChapter.waitForExistence(timeout: 5))
            // Three columns require 420 pt of document, 320 pt of conversation,
            // 248 pt of outline and one 16 pt outer panel inset in the design contract.
            let threeColumnMinimum: CGFloat = 420 + 320 + 248 + 16
            if app.windows.firstMatch.frame.width >= threeColumnMinimum {
                XCTAssertTrue(input.exists)
                assertCloseAtLeading()
                record("adaptive-wide-directory-and-conversation")
            } else {
                XCTAssertTrue(input.waitForNonExistence(timeout: 5))
                record("adaptive-side-directory-switch")
                showTools(app)
                app.buttons["GlobalAI"].tap()
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                XCTAssertEqual(input.value as? String, draft)
                XCTAssertTrue(firstChapter.waitForNonExistence(timeout: 5))
                assertCloseAtLeading()
            }
            let keyboard = app.keyboards.firstMatch
            let hideKeyboard = app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Hide keyboard", "Hide Keyboard"])
            ).firstMatch
            if hideKeyboard.exists {
                hideKeyboard.tap()
            } else {
                app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].firstMatch.tap()
            }
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
            let restored = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    input.frame.maxY > app.windows.firstMatch.frame.maxY - 100 && input.value as? String == draft
                }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [restored], timeout: 8), .completed,
                "Hiding the keyboard must restore the full-height conversation: \(input.frame), app \(app.windows.firstMatch.frame)"
            )
            record("adaptive-conversation-keyboard-dismissed")
            app.buttons["CollapseAgent"].tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertEqual(close.frame.minX, trailingClose.minX, accuracy: 1)
            showTools(app)
            app.buttons["GlobalAI"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            assertCloseAtLeading()
            XCTAssertFalse(app.buttons["ToolsToggle"].exists)
            app.buttons["CollapseAgent"].tap()
            showTools(app)
            app.buttons["ModeToggle"].tap()
            XCTAssertTrue(app.textViews["SourceEditor"].waitForExistence(timeout: 8))
            showTools(app)
            app.buttons["GlobalAI"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, draft)
            XCTAssertFalse(app.buttons["ToolsToggle"].exists)
            XCTAssertFalse(outline.exists)
            XCTAssertEqual(close.frame.minX, 8, accuracy: 1)
            record("adaptive-source-close-leading")
            close.tap()
            XCTAssertTrue(app.buttons["OpenDocument"].waitForExistence(timeout: 8))
        } else {
            XCTAssertLessThan(input.frame.minX, app.windows.firstMatch.frame.width / 4)
            outline.tap()
            XCTAssertTrue(input.waitForNonExistence(timeout: 5))
            XCTAssertTrue(firstChapter.waitForExistence(timeout: 5))
            record("adaptive-narrow-directory-switch")
            showTools(app)
            app.buttons["GlobalAI"].tap()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(input.value as? String, draft)
            XCTAssertTrue(firstChapter.waitForNonExistence(timeout: 5))
        }
    }

    func testConversationManualBrowsingAndFollowingSurviveComposerResizeAndRotation() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let answerEnds = app.webViews.staticTexts.matching(identifier: "保留原有格式")
        func appendLine(_ text: String) {
            pressSoftwareReturnAtEnd(of: input, app: app)
            input.typeText(text)
        }
        for turn in 1...5 {
            if turn == 1 { input.tap() } else { waitForVisibleSoftwareKeyboard(in: app) }
            input.typeText("Reading question \(turn)")
            tapAfterTyping(app.buttons["SendAgentMessage"], in: app)
            if turn == 1 { allowDataSharingIfRequested(app) }
            let end = answerEnds.element(boundBy: turn - 1)
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in end.isHittable }, object: nil)],
                    timeout: 10), .completed)
        }
        let conversation = app.webViews["ConversationWebView"]
        XCTAssertTrue(conversation.exists)
        let firstQuestion = app.webViews.staticTexts["Reading question 1"]
        func isVisible(_ element: XCUIElement) -> Bool {
            let viewport = conversation.frame.intersection(app.windows.firstMatch.frame)
            return !viewport.isEmpty && viewport.contains(element.frame)
        }
        for _ in 0..<8 where !isVisible(firstQuestion) { conversation.swipeDown() }
        XCTAssertTrue(isVisible(firstQuestion), "Real touch scrolling must reveal the first question")
        let initialOffset = firstQuestion.frame.minY - conversation.frame.minY
        let initialLineHeight = firstQuestion.frame.height
        input.tap()
        input.typeText("draft")
        appendLine("second line")
        XCTAssertEqual(input.value as? String, "draft\nsecond line")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate { _, _ in
                            isVisible(firstQuestion)
                                && abs(firstQuestion.frame.minY - conversation.frame.minY - initialOffset) < 2
                        }, object: nil)
                ], timeout: 8), .completed, "Growing the composer must preserve manual reading")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            rotate(to: orientation, in: app)
            // Rotation can change panel padding and shorten the viewport below
            // the keyboard. Preserve the reading offset, then verify visibility
            // again when the original viewport is restored.
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [
                        XCTNSPredicateExpectation(
                            predicate: NSPredicate { _, _ in
                                // WebKit rebuilds its accessibility subtree during rotation.
                                // Avoid implicit frame-resolution retries while it is absent.
                                guard firstQuestion.exists && conversation.exists && input.exists else { return false }
                                return abs(firstQuestion.frame.minY - conversation.frame.minY - initialOffset)
                                    < min(initialLineHeight, firstQuestion.frame.height)
                                    && input.value as? String == "draft\nsecond line"
                            }, object: nil)
                    ], timeout: 8), .completed,
                "Rotation must preserve the draft and reading offset within one line; original offset \(initialOffset), "
                    + "question \(firstQuestion.frame), conversation \(conversation.frame)")
        }
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in isVisible(firstQuestion) }, object: nil)
                ],
                timeout: 8), .completed,
            "Restoring the original viewport must reveal the same question without scrolling")
        let lastAnswer = answerEnds.element(boundBy: 4)
        for _ in 0..<8 where !isVisible(lastAnswer) { conversation.swipeUp() }
        XCTAssertTrue(isVisible(lastAnswer), "Real touch scrolling must return to the latest answer")
        input.tap()
        for line in ["third line", "fourth line", "fifth line"] { appendLine(line) }
        XCTAssertEqual(input.value as? String, "draft\nsecond line\nthird line\nfourth line\nfifth line")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in isVisible(lastAnswer) }, object: nil)],
                timeout: 8), .completed, "Returning to the end must restore following when the composer grows")
    }

    func testNativeSelectionQuestionMenu() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-model-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "这是一份可以实际滚动"))
            .firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 25))
        waitForEnabled(app.buttons["OutlineToggle"])
        paragraph.press(forDuration: 1.2)
        let selection = XCTAttachment(string: app.debugDescription)
        selection.name = "native-selection-menu-hierarchy"
        selection.lifetime = .keepAlways
        add(selection)
        record("native-selection-menu")
        // Selection handles can remain visible with the system edit menu hidden.
        // Tapping the selected text requests that menu through UIKit's normal gesture.
        if !app.menuItems.firstMatch.waitForExistence(timeout: 6) {
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let ask = app.menuItems["在 AI 对话中引用…"]
        XCTAssertTrue(ask.waitForExistence(timeout: 6))
        ask.tap()
        XCTAssertTrue(app.descendants(matching: .any)["QuestionInput"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["SendAgentMessage"].label, "发送问题")
        record("selection-question")
        app.buttons["CollapseAgent"].tap()
    }

    private func openImageReader(_ app: XCUIApplication, language: String, locale: String) -> XCUIElement {
        SimulatorOrientation.set(UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait)
        app.launchArguments = [
            "--ui-testing", "--ui-test-model-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
        ]
        app.launch()
        let toggle = app.buttons["OutlineToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 25))
        waitForEnabled(toggle)
        let chapter = app.webViews.links["6.1 Markdown 图片"]
        if !chapter.exists { toggle.tap() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 8))
        chapter.tap()
        if chapter.exists { toggle.tap() }
        let image = app.webViews.descendants(matching: .any).matching(identifier: "市场结构示意图").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 8))
        return image
    }

    func testImageTapMenuOpensACompleteImageQuote() {
        let app = XCUIApplication()
        for (language, locale, title, reference) in [
            ("zh-Hans", "zh_CN", "在 AI 对话中引用…", "引用"),
            ("en", "en_US", "Reference in AI Chat…", "Reference"),
        ] {
            let image = openImageReader(app, language: language, locale: locale)
            image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let action = app.menuItems[title]
            XCTAssertTrue(action.waitForExistence(timeout: 6))
            XCTAssertEqual(app.menuItems.matching(identifier: title).count, 1)
            record("image-tap-menu-\(language)")
            action.tap()
            XCTAssertTrue(app.textViews["QuestionInput"].waitForExistence(timeout: 8))
            let quote = app.webViews["ConversationWebView"].otherElements[reference]
                .descendants(matching: .any).matching(identifier: "市场结构示意图").firstMatch
            XCTAssertTrue(quote.waitForExistence(timeout: 5))
            XCTAssertTrue(quote.elementType == .image || quote.images.firstMatch.exists)
            record("image-quote-composer-\(language)")
            app.terminate()
        }
    }

    // TODO: Restore after diagnosing preview dismissal without a system menu in Simulator
    // and validating Copy, Share and Live Text reliably in full iPhone and iPad runs.
    // func testImageLongPressRetainsSystemCopyShareAndRecognition() throws {
    //     try useComponentSynchronization()
    //     let app = XCUIApplication()
    //     let image = openImageReader(app, language: "zh-Hans", locale: "zh_CN")
    //     // Press the drawing's empty leading edge, rather than its OCR text.
    //     image.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).press(forDuration: 1.2)
    //     let copy = app.buttons["拷贝"]
    //     XCTAssertTrue(copy.waitForExistence(timeout: 8))
    //     XCTAssertTrue(copy.isHittable)
    //     XCTAssertTrue(app.buttons["共享…"].exists)
    //     XCTAssertTrue(app.buttons["共享…"].isHittable)
    //     XCTAssertTrue(app.buttons["显示文本"].waitForExistence(timeout: 8))
    //     XCTAssertTrue(app.buttons["显示文本"].isHittable)
    //     XCTAssertFalse(app.menuItems["在 AI 对话中引用…"].exists)
    //     record("image-original-system-menu")
    //     app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
    //     XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
    // }

    @discardableResult
    private func waitForVisibleSoftwareKeyboard(
        in app: XCUIApplication, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement {
        let keyboard = app.keyboards.firstMatch
        let visible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard keyboard.exists else { return false }
                let intersection = keyboard.frame.intersection(app.windows.firstMatch.frame)
                return !intersection.isNull && intersection.height > 0
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [visible], timeout: timeout), .completed,
            "The software keyboard must occupy the screen; a hidden preview node is insufficient.",
            file: file, line: line)
        return keyboard
    }

    private func tapAfterTyping(
        _ control: XCUIElement, in app: XCUIApplication,
        beside input: XCUIElement? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Synthetic typing temporarily hides the software keyboard. Resolve the
        // next hit point after its return has restored the visible layout.
        let keyboard = waitForVisibleSoftwareKeyboard(in: app, file: file, line: line)
        if let input {
            // A returning keyboard can exist while the Web button and native
            // input still describe different layouts. Resolve their shared row
            // above the fully visible keyboard before choosing a touch point.
            let aligned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    let keys = keyboard.frame
                    let field = input.frame
                    let button = control.frame
                    return !keys.isEmpty && app.windows.firstMatch.frame.contains(keys)
                        && abs(field.maxX - button.minX) < 1
                        && field.minY <= button.midY && button.midY <= field.maxY
                        && max(field.maxY, button.maxY) <= keys.minY
                        && input.isHittable && control.isHittable
                }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [aligned], timeout: 5), .completed,
                "Native input \(input.frame), control \(control.frame), keyboard \(keyboard.frame)",
                file: file, line: line)
        }
        XCTAssertEqual(
            app.menuItems.count, 0, "Typing must not introduce an unrelated editing menu",
            file: file, line: line)
        XCTAssertTrue(control.isHittable, file: file, line: line)
        control.tap()
    }

    private func pressSoftwareReturnAtEnd(of input: XCUIElement, app: XCUIApplication) {
        // Appending deliberately positions the caret after the visible draft.
        // Synthetic typing hides the keyboard temporarily; do not choose the
        // caret's touch coordinate from that intermediate input layout.
        let keyboard = waitForVisibleSoftwareKeyboard(in: app)
        let inputReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                input.isHittable && !input.frame.isEmpty && input.frame.maxY <= keyboard.frame.minY
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [inputReady], timeout: 5), .completed)
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        let returnKey = keyboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["return", "Return", "换行"]))
            .firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 3), keyboard.debugDescription)
        XCTAssertTrue(returnKey.isHittable, keyboard.debugDescription)
        returnKey.tap()
    }

    private func showTools(_ app: XCUIApplication) {
        let toggle = app.buttons["ToolsToggle"]
        let mode = app.buttons["ModeToggle"]
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "Both document modes retain the disclosure after the foreground closing transition")
        waitForEnabled(toggle)
        if !mode.exists { toggle.tap() }
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
    }

    private func waitForEnabled(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, file: file, line: line)
    }

    /// Acknowledge each injected line before sending the next Return.
    private func typeSource(
        _ text: String, into editor: XCUIElement, file: StaticString = #filePath, line: UInt = #line
    ) {
        for (index, part) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                let before = editor.value as? String
                editor.typeText("\n")
                let newline = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in (editor.value as? String) != before }, object: nil)
                guard XCTWaiter.wait(for: [newline], timeout: 8) == .completed else {
                    XCTFail("The editor did not commit the newline", file: file, line: line)
                    return
                }
            }
            guard !part.isEmpty else { continue }
            editor.typeText(part)
            let committed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in (editor.value as? String)?.contains(part) == true }, object: nil)
            guard XCTWaiter.wait(for: [committed], timeout: 8) == .completed else {
                XCTFail("The editor did not commit the complete input line", file: file, line: line)
                return
            }
        }
    }

    private func openQuestionInput(_ app: XCUIApplication) -> XCUIElement {
        SimulatorOrientation.set(.portrait)
        app.launchArguments = [
            "--ui-testing", "--ui-test-model-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        input.tap()
        XCTAssertEqual(input.value as? String, "")
        return input
    }

    func testQuestionSoftwareKeyboardReturn() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("first")
        pressSoftwareReturnAtEnd(of: input, app: app)
        input.typeText("second")
        XCTAssertEqual(input.value as? String, "first\nsecond")
        let validation = app.webViews.staticTexts["无法连接到服务"]
        XCTAssertFalse(validation.exists)
        record("question-software-return-newline")
    }

    func testUnconfiguredAIShowsPromptAndSettingsReturnsToInput() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.webViews.staticTexts["Markdown 长文阅读与技术笔记"].waitForExistence(timeout: 25))
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let alert = app.alerts["尚未配置 AI 模型"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["QuestionInput"].exists)
        record("unconfigured-ai-prompt")
        alert.buttons["取消"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["前往设置"].tap()
        let base = app.textFields["ModelBaseURL"]
        XCTAssertTrue(base.waitForExistence(timeout: 5))
        base.tap()
        base.typeText("http://127.0.0.1:1/v1")
        waitForVisibleSoftwareKeyboard(in: app)
        XCTAssertEqual(app.menuItems.count, 0)
        app.buttons["ModelPicker"].tap()
        app.buttons["自定义…"].tap()
        let model = app.textFields["ModelID"]
        model.tap()
        model.typeText("ui-test-model")
        let key = app.secureTextFields["ModelAPIKey"]
        tapAfterTyping(key, in: app)
        key.typeText("ui-test-only-key")
        tapAfterTyping(app.buttons["SettingsDone"], in: app)
        XCTAssertTrue(app.textViews["QuestionInput"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.buttons["SendAgentMessage"].label, "发送问题")
        XCTAssertFalse(app.buttons["SendAgentMessage"].isEnabled)
        XCTAssertEqual(app.webViews.otherElements.matching(identifier: "用户提问").count, 0)
        record("configured-return-to-input")
    }

    func testAgentFailureRetryPreservesDraftAndConversation() throws {
        try useComponentSynchronization()
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("Explain Markdown.")
        XCTAssertEqual(input.value as? String, "Explain Markdown.")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app)
        allowDataSharingIfRequested(app)
        let retry = app.webViews.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        input.typeText("unsent next question")
        tapAfterTyping(retry, in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unsent next question")
        XCTAssertEqual(
            app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "Explain Markdown.")).count, 1)
        if input.frame.minX < app.windows.firstMatch.frame.midX {
            XCTAssertFalse(app.buttons["ToolsToggle"].exists)
            XCTAssertFalse(app.buttons["CloseDocument"].exists)
            XCTAssertTrue(app.buttons["OutlineToggle"].isHittable)
        }
        record("agent-failure-retry-draft")
        app.buttons["CollapseAgent"].tap()
        showTools(app)
        app.buttons["GlobalAI"].tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unsent next question")
        record("agent-reopened-history")
    }

    func testClearConversationConfirmsAndPreservesDraft() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        if UIDevice.current.userInterfaceIdiom == .pad { rotate(to: .landscapeLeft, in: app) }
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let clear = app.buttons["ClearAgentHistory"]
        XCTAssertTrue(clear.exists)
        XCTAssertFalse(clear.isEnabled)
        input.tap()
        input.typeText("Explain the document in Chinese.")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        allowDataSharingIfRequested(app)
        let reply = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "这份文档演示了"))
            .firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 8))
        record("conversation-clear-button")
        input.tap()
        input.typeText("Keep this draft.")
        tapAfterTyping(clear, in: app)
        let confirmation = app.alerts["清空历史？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        record("conversation-clear-confirmation")
        confirmation.buttons["CancelClearAgentHistory"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this draft.")
        XCTAssertTrue(app.webViews.staticTexts["Explain the document in Chinese."].exists)
        clear.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["ConfirmClearAgentHistory"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Explain the document in Chinese."].waitForNonExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "Keep this draft.")
        XCTAssertFalse(clear.isEnabled)
        record("conversation-cleared-draft-retained")
    }

    func testQuestionKeyboardSendButton() {
        let app = XCUIApplication()
        let input = openQuestionInput(app)
        input.typeText("a question")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app)
        allowDataSharingIfRequested(app)
        XCTAssertTrue(app.webViews.staticTexts["无法连接到服务"].waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "")
        XCTAssertEqual(app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", "a question")).count, 1)
        record("question-send-button")
    }
}

extension ReaderUITests {
    func testAnnotationsUseSystemSelectionAndOneNativeEditor() {
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--sample-document", "--reset-sample-document", "-AppleLanguages", "(en)", "-AppleLocale",
            "en_US",
        ]
        app.launch()
        let paragraph = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "这是一份可以实际滚动"))
            .firstMatch
        XCTAssertTrue(paragraph.waitForExistence(timeout: 25))
        waitForEnabled(app.buttons["OutlineToggle"])
        paragraph.press(forDuration: 1.2)
        if !app.menuItems.firstMatch.waitForExistence(timeout: 6) {
            paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        record("annotation-selection-menu")
        let add = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label == %@ AND elementType IN %@", "Add Annotation…",
                [XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue])
        ).firstMatch
        // UIKit paginates the standard edit menu according to available width.
        // Follow its visible paging control, just as a reader would.
        var pages = Set<[String]>()
        while !add.exists {
            let titles = app.menuItems.allElementsBoundByIndex.map(\.label)
            let next = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next Page", "Forward"]))
                .firstMatch
            guard pages.insert(titles).inserted, next.exists, next.isHittable else { break }
            next.tap()
        }
        XCTAssertTrue(add.waitForExistence(timeout: 6))
        XCTAssertTrue(add.isHittable)
        add.tap()
        let input = app.textViews["AnnotationInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        waitForVisibleSoftwareKeyboard(in: app)
        input.typeText("A lasting thought.")
        let done = app.buttons["AnnotationDone"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 6))
        let marker = app.webViews.buttons["Annotation"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 6))
        marker.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 6))
        XCTAssertEqual(input.value as? String, "A lasting thought.")
        record("native-annotation-card")
        app.buttons["AnnotationCancel"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 6))
    }
    private func openSearchSettings(_ app: XCUIApplication, title: String = "Model Settings") {
        showTools(app)
        app.buttons["More"].tap()
        app.buttons[title].tap()
        XCTAssertTrue(app.buttons["SearchProvider"].waitForExistence(timeout: 8))
    }

    private func chooseSearchProvider(_ title: String, in app: XCUIApplication) {
        app.buttons["SearchProvider"].tap()
        let provider = app.buttons[title]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
    }

    private func saveSearchSettings(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let hide = app.buttons.matching(NSPredicate(format: "label IN %@", ["Hide keyboard", "Hide Keyboard"]))
                .firstMatch
            if hide.exists && hide.isHittable {
                hide.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            app.buttons["SettingsDone"].tap()
        } else {
            tapAfterTyping(app.buttons["SettingsDone"], in: app)
        }
        XCTAssertTrue(app.buttons["SettingsDone"].waitForNonExistence(timeout: 8))
    }

    func testOptionalSearchConfigurationKeepsProviderKeysAndResetIsExplicit() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        openSearchSettings(app, title: "模型设置")
        XCTAssertFalse(app.secureTextFields["SearchAPIKey"].exists)
        chooseSearchProvider("Serper", in: app)
        app.buttons["SettingsDone"].tap()
        let missing = app.alerts["请输入搜索服务的 API Key。"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        missing.buttons["好"].tap()
        let key = app.secureTextFields["SearchAPIKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("serper-ui-test-only")
        tapAfterTyping(app.buttons["SearchProvider"], in: app)
        app.buttons["Brave Search"].tap()
        XCTAssertTrue((key.value as? String ?? "").isEmpty)
        app.buttons["SearchProvider"].tap()
        app.buttons["Serper"].tap()
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        record("search-settings-configured")
        app.buttons["SettingsDone"].tap()
        XCTAssertTrue(app.buttons["SettingsDone"].waitForNonExistence(timeout: 8))
        openSearchSettings(app, title: "模型设置")
        XCTAssertFalse((key.value as? String ?? "").isEmpty)
        app.buttons["ResetModelSettings"].tap()
        let reset = app.alerts["重置模型设置？"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.buttons["重置"].tap()
        XCTAssertTrue(key.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.textFields["ModelBaseURL"].value as? String, "https://api.example.com/v1")
        app.buttons["取消"].tap()
    }

    func testConfiguredSearchConsentCanBeDeclinedThenAllowedAndRendersSourceLinks() throws {
        try useComponentSynchronization()
        SimulatorOrientation.set(.portrait)
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--ui-test-agent-fixture", "--sample-document", "--reset-sample-document",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["ToolsToggle"].waitForExistence(timeout: 25))
        openSearchSettings(app)
        chooseSearchProvider("Serper", in: app)
        let key = app.secureTextFields["SearchAPIKey"]
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap()
        key.typeText("serper-ui-test-only")
        saveSearchSettings(app)
        showTools(app)
        app.buttons["GlobalAI"].tap()
        let input = app.textViews["QuestionInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap()
        input.typeText("SEARCH_PUBLIC_REFERENCE")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        allowDataSharingIfRequested(app)
        let cancel = app.alerts.buttons["CancelSearchDataSharing"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8))
        record("search-first-use-consent")
        cancel.tap()
        XCTAssertTrue(
            app.webViews.staticTexts["Continue using the document without web search."].waitForExistence(timeout: 8))
        input.tap()
        input.typeText("SEARCH_PUBLIC_REFERENCE again")
        tapAfterTyping(app.buttons["SendAgentMessage"], in: app, beside: input)
        let allow = app.alerts.buttons["AllowSearchDataSharing"].firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 8))
        allow.tap()
        XCTAssertTrue(app.webViews.links["Markdown reference"].waitForExistence(timeout: 8))
        record("search-answer-source-link")
    }

}
