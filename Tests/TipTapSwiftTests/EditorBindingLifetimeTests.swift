#if os(macOS) || os(iOS)
import XCTest
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import TipTapSwift

final class EditorBindingLifetimeTests: XCTestCase {
    @MainActor
    func testHostedEditorInsertsImageWithMultilineQuotedAltThroughContext() async throws {
        let ready = expectation(description: "Editor initialized")
        let inserted = expectation(description: "Image insertion reaches the binding")
        var content = "<p>Before image</p><p>After image</p>"
        var didInsert = false
        let context = EditorContext()
        let mounted = MountedEditorView(EditorWebSurface(
            htmlContent: Binding(get: { content }, set: { html in
                content = html
                if !didInsert, html.contains("<img ") {
                    didInsert = true
                    inserted.fulfill()
                }
            }),
            editorContext: context,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let url = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        let alt = "First line\nSecond line\rThird line 'single' \"double\" \\path"

        context.insertImage(url: url, alt: alt)
        await fulfillment(of: [inserted], timeout: 5)

        let image = try await webView.evaluateJavaScript("""
            (() => {
                const images = document.querySelectorAll('.tiptap img');
                return {
                    count: images.length,
                    src: images[0]?.getAttribute('src'),
                    alt: images[0]?.getAttribute('alt'),
                    paragraphs: Array.from(document.querySelectorAll('.tiptap p'))
                        .map(element => element.textContent).filter(Boolean)
                };
            })()
            """) as? [String: Any]
        let result = try XCTUnwrap(image)
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["src"] as? String, url)
        XCTAssertEqual(result["alt"] as? String, alt)
        XCTAssertEqual(result["paragraphs"] as? [String], ["Before image", "After image"])
        let rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(content, rendered)
    }

    @MainActor
    func testHostedEditorUsesLatestBindingValueBeforeReadiness() async throws {
        let ready = expectation(description: "Latest content initialized")
        var content = "<p>Original</p>"
        let context = EditorContext()
        let editor = EditorWebSurface(
            htmlContent: Binding(get: { content }, set: { content = $0 }),
            editorContext: context,
            onEditorReady: { ready.fulfill() }
        )
        let mounted = MountedEditorView(editor)
        defer { mounted.close() }
        let webView = try XCTUnwrap(context.webView)

        // The coordinator exists, but the main actor has not yielded to WebKit.
        content = "<p>Changed before readiness</p>"
        await fulfillment(of: [ready], timeout: 15)

        let rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(rendered, "<p>Changed before readiness</p>")
        XCTAssertEqual(content, "<p>Changed before readiness</p>")
    }

    @MainActor
    func testHostedEditorWritesReplacementBindingAfterSwiftUIUpdate() async throws {
        let ready = expectation(description: "Original editor initialized")
        let edited = expectation(description: "Formatting reaches replacement binding")
        var original = "<p>Original</p>"
        var replacement = "<p>Replacement</p>"
        let context = EditorContext()
        let replacementContext = EditorContext()
        let mounted = MountedEditorView(EditorWebSurface(
            htmlContent: Binding(get: { original }, set: { original = $0 }),
            editorContext: context,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)

        mounted.replace(EditorWebSurface(
            htmlContent: Binding(
                get: { replacement },
                set: { html in
                    replacement = html
                    if html == "<h2>Replacement</h2><p></p>" { edited.fulfill() }
                }
            ),
            editorContext: replacementContext
        ))
        // Await the actual document update, not an assumed SwiftUI/render deadline.
        let deadline = Date().addingTimeInterval(5)
        var rendered: String?
        repeat {
            rendered = try await evaluateEditorJavaScript("window.getContent()", in: webView) as? String
            if rendered == "<p>Replacement</p>" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertEqual(rendered, "<p>Replacement</p>")
        XCTAssertNil(context.webView, "The previous command context must lose its editor")
        XCTAssertTrue(replacementContext.webView === webView, "The new context must reuse the original editor")

        replacementContext.toggleHeading(level: 2)
        await fulfillment(of: [edited], timeout: 2)
        XCTAssertEqual(original, "<p>Original</p>")
        XCTAssertEqual(replacement, "<h2>Replacement</h2><p></p>")
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? EditorWebSurface.Coordinator)
        #if os(macOS)
        EditorWebSurface.dismantle(webView, coordinator: coordinator)
        #else
        EditorWebSurface.dismantle(webView, coordinator: coordinator)
        #endif
        try await waitForEditorState("Dismantled context detaches") { replacementContext.webView == nil }
        XCTAssertNil(replacementContext.webView)
        XCTAssertFalse(replacementContext.isReady)
    }

    #if os(iOS)
    @MainActor
    func testPublicEditorReplacesKeyboardGuideToolbarAndFormattingOwner() async throws {
        let ready = expectation(description: "Public editor initialized")
        let replacementReady = expectation(description: "Replacement public editor initialized")
        let edited = expectation(description: "Formatting reaches current public binding")
        var original = "<p>Original</p>"
        var replacement = "<p>Replacement</p>"
        let context = EditorContext()
        let replacementContext = EditorContext()
        let mounted = MountedEditorView(RichTextEditorView(
            htmlContent: Binding(get: { original }, set: { original = $0 }),
            editorContext: context, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let originalToolbar = try await focusedKeyboardToolbar(in: webView, context: context)

        mounted.replace(RichTextEditorView(
            htmlContent: Binding(get: { replacement }, set: {
                replacement = $0
                if $0 == "<h2>Replacement</h2><p></p>" { edited.fulfill() }
            }),
            editorContext: replacementContext, onEditorReady: { replacementReady.fulfill() }
        ))
        await fulfillment(of: [replacementReady], timeout: 15)
        let replacementWebView = try XCTUnwrap(replacementContext.webView)
        XCTAssertFalse(replacementWebView === webView, "Public context identity replaces the native container")
        try await waitForEditorState("Previous public context detaches") { context.webView == nil }
        XCTAssertFalse(context.isReady)
        let replacementToolbar = try await focusedKeyboardToolbar(in: replacementWebView, context: replacementContext)
        XCTAssertFalse(replacementToolbar === originalToolbar)
        XCTAssertNil(originalToolbar.window)

        context.toggleHeading(level: 3)
        replacementContext.toggleHeading(level: 2)
        await fulfillment(of: [edited], timeout: 5)
        try await waitForEditorState("Current toolbar receives heading state") {
            replacementContext.activeFormats.contains("heading2")
        }
        XCTAssertEqual(original, "<p>Original</p>")
        XCTAssertEqual(replacement, "<h2>Replacement</h2><p></p>")

        mounted.close()
        try await waitForEditorState("Closed public editor detaches") { replacementContext.webView == nil }
        XCTAssertFalse(replacementContext.isReady)
        XCTAssertFalse(replacementContext.isFocused)
        XCTAssertTrue(replacementContext.activeFormats.isEmpty)
    }

    @MainActor
    private func focusedKeyboardToolbar(in webView: WKWebView, context: EditorContext) async throws -> UIView {
        var responder: UIResponder? = webView
        while responder != nil && !(responder is EditorViewController) { responder = responder?.next }
        let controller = try XCTUnwrap(responder as? EditorViewController)
        XCTAssertTrue(controller.context === context)
        let toolbar = try XCTUnwrap(controller.view.subviews.first {
            $0.accessibilityIdentifier == "RichTextEditor.FormattingToolbarHost"
        })
        XCTAssertTrue(context.isReady)
        XCTAssertTrue(controller.view.keyboardLayoutGuide.followsUndockedKeyboard)
        // Use the real DOM/bridge focus path, rather than manufacturing context state.
        _ = try await evaluateEditorJavaScript("window.focus(); true", in: webView)
        try await waitForEditorState("Native toolbar follows ready, focused editor") {
            context.isFocused && !toolbar.isHidden && toolbar.window != nil
        }
        controller.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(toolbar.frame.height, 52, accuracy: 1)
        XCTAssertGreaterThan(toolbar.frame.width, 0)
        XCTAssertLessThanOrEqual(toolbar.frame.maxY, controller.view.bounds.maxY + 1)
        let keyboard = controller.view.keyboardLayoutGuide.layoutFrame
        let safeArea = controller.view.safeAreaLayoutGuide.layoutFrame
        // UITrackingLayoutGuide chooses its own near-top threshold. Both
        // supported placements must keep the toolbar on a public guide edge.
        XCTAssertLessThanOrEqual(min(abs(toolbar.frame.maxY - keyboard.minY),
                                     abs(toolbar.frame.maxY - safeArea.maxY)), 1)
        let docked = keyboard.height > 1 && keyboard.maxY >= controller.view.bounds.maxY - 1
            && keyboard.width >= safeArea.width - 1
        if keyboard.height <= 1 || docked || toolbar.frame.maxY >= safeArea.maxY - 1 {
            XCTAssertLessThanOrEqual(webView.frame.maxY, toolbar.frame.minY + 1)
        }
        return toolbar
    }
    #endif

    @MainActor
    private func evaluateEditorJavaScript(_ script: String, in webView: WKWebView) async throws -> Any? {
        let completed = expectation(description: "Editor JavaScript reply")
        var result: Result<Any?, Error>?
        var acceptingReply = true
        webView.evaluateJavaScript(script) { value, error in
            guard acceptingReply else { return }
            result = error.map { .failure($0) } ?? .success(value)
            completed.fulfill()
        }
        // Bound the IPC callback itself; a polling deadline cannot do that.
        await fulfillment(of: [completed], timeout: 5)
        acceptingReply = false
        return try XCTUnwrap(result, "Editor JavaScript did not settle").get()
    }

    @MainActor
    private func waitForEditorState(_ description: String, timeout: TimeInterval = 5,
                                    _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            try Task.checkCancellation()
            guard Date() < deadline else {
                XCTFail(description)
                throw NSError(domain: "EditorBindingLifetimeTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: description])
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func testHostedEditorRejectsQueuedContentDuringBindingReplacement() async throws {
        let ready = expectation(description: "Original editor initialized")
        let originalEdited = expectation(description: "Actual original content callback retained")
        let replacementReceived = expectation(description: "Replacement callback intercepted before publication")
        let currentEdited = expectation(description: "Current formatting reaches replacement binding")
        var original = "<p>Original</p>"
        var replacement = "<p>Replacement</p>"
        var replacementWrites: [String] = []
        let originalContext = EditorContext()
        let replacementContext = EditorContext()
        let mounted = MountedEditorView(EditorWebSurface(
            htmlContent: Binding(get: { original }, set: { original = $0 }),
            editorContext: originalContext,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(originalContext.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? EditorWebSurface.Coordinator)
        // A queued command has already captured this owner even if its original
        // EditorContext is detached before WebKit executes the command.
        let queuedCommandContext = EditorContext()
        queuedCommandContext.bind(to: webView, contentGeneration: coordinator.contentGeneration)
        var retainedOriginal: WKScriptMessage?
        var interceptReplacement = false
        let relay = EditorMessageRelay { controller, message in
            if retainedOriginal == nil {
                coordinator.userContentController(controller, didReceive: message)
                if (message.body as? [String: Any])?["html"] as? String == "<h1>Original</h1><p></p>" {
                    retainedOriginal = message
                    originalEdited.fulfill()
                }
                return
            }
            if interceptReplacement, let retainedOriginal,
               (message.body as? [String: Any])?["contentGeneration"] as? String
                != (retainedOriginal.body as? [String: Any])?["contentGeneration"] as? String {
                interceptReplacement = false
                XCTAssertTrue(coordinator.parent.editorContext === replacementContext)
                XCTAssertEqual(replacement, "<p>Replacement</p>")
                XCTAssertTrue(replacementWrites.isEmpty)
                // B's actual setContent callback is held here. Deliver A on the
                // same live WebView/main frame before allowing B to publish.
                coordinator.userContentController(controller, didReceive: retainedOriginal)
                XCTAssertEqual(replacement, "<p>Replacement</p>")
                XCTAssertTrue(replacementWrites.isEmpty, "A must never transiently overwrite B")
                replacementReceived.fulfill()
            }
            coordinator.userContentController(controller, didReceive: message)
        }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "contentChanged")
        controller.add(relay, name: "contentChanged")
        defer { controller.removeScriptMessageHandler(forName: "contentChanged") }
        originalContext.toggleHeading(level: 1)
        await fulfillment(of: [originalEdited], timeout: 5)
        let oldMessage = try XCTUnwrap(retainedOriginal)
        XCTAssertTrue(oldMessage.webView === webView && oldMessage.frameInfo.isMainFrame)
        let oldHTML = try XCTUnwrap((oldMessage.body as? [String: Any])?["html"] as? String)
        XCTAssertEqual(original, oldHTML)

        interceptReplacement = true
        mounted.replace(EditorWebSurface(
            htmlContent: Binding(get: { replacement }, set: {
                replacement = $0
                replacementWrites.append($0)
                if $0 == "<h2>Replacement</h2><p></p>" { currentEdited.fulfill() }
            }),
            editorContext: replacementContext
        ))
        await fulfillment(of: [replacementReceived], timeout: 5)
        XCTAssertTrue(mounted.webView === webView)
        XCTAssertNil(originalContext.webView)
        XCTAssertTrue(replacementContext.webView === webView)
        coordinator.userContentController(controller, didReceive: oldMessage)
        queuedCommandContext.toggleHeading(level: 3)
        originalContext.toggleHeading(level: 3)
        let rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(rendered, "<p>Replacement</p>")
        XCTAssertEqual(replacement, "<p>Replacement</p>")
        XCTAssertFalse(replacementWrites.contains(oldHTML))

        replacementContext.toggleHeading(level: 2)
        await fulfillment(of: [currentEdited], timeout: 5)
        XCTAssertEqual(replacement, "<h2>Replacement</h2><p></p>")
        XCTAssertEqual(original, oldHTML)
    }

    @MainActor
    func testHostedEditorCanRevertAPendingReplacementToItsPreviousValue() async throws {
        let ready = expectation(description: "Original editor initialized")
        let reverted = expectation(description: "Pending replacement retired by the original value")
        var content = "<p>Original</p>"
        let binding = Binding(get: { content }, set: { content = $0 })
        let context = EditorContext()
        let mounted = MountedEditorView(EditorWebSurface(
            htmlContent: binding, editorContext: context, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? EditorWebSurface.Coordinator)
        var didRevert = false
        let relay = EditorMessageRelay { controller, message in
            if !didRevert, (message.body as? [String: Any])?["html"] as? String == "<p>Temporary</p>" {
                didRevert = true
                content = "<p>Original</p>"
                // The binding has changed before the next SwiftUI update.
                // Keep the same context and deliver B now: it must yield to A,
                // even though A equals the last accepted JavaScript content.
                coordinator.userContentController(controller, didReceive: message)
                XCTAssertEqual(content, "<p>Original</p>")
                reverted.fulfill()
                return
            }
            coordinator.userContentController(controller, didReceive: message)
        }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "contentChanged")
        controller.add(relay, name: "contentChanged")
        defer { controller.removeScriptMessageHandler(forName: "contentChanged") }
        content = "<p>Temporary</p>"
        mounted.replace(EditorWebSurface(htmlContent: binding, editorContext: context))
        await fulfillment(of: [reverted], timeout: 5)
        let rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(rendered, "<p>Original</p>")
        XCTAssertEqual(content, "<p>Original</p>")
        XCTAssertTrue(mounted.webView === webView)
    }

    @MainActor
    func testHostedEditorRejectsContentFromSupersededInitialization() async throws {
        let ready = expectation(description: "Latest initialization completes once")
        var content = "<p>Original</p>"
        let context = EditorContext()
        let mounted = MountedEditorView(EditorWebSurface(
            htmlContent: Binding(get: { content }, set: { content = $0 }),
            editorContext: context,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        let webView = try XCTUnwrap(context.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? EditorWebSurface.Coordinator)
        var retainedOriginal: WKScriptMessage?
        let relay = EditorMessageRelay { controller, message in
            if retainedOriginal == nil,
               (message.body as? [String: Any])?["html"] as? String == "<p>Original</p>",
               (message.body as? [String: Any])?["contentGeneration"] as? String == coordinator.contentGeneration {
                XCTAssertFalse(coordinator.isEditorReady)
                retainedOriginal = message
                // The initial setContent has executed, but its normalization
                // completion has not published readiness or a binding value.
                content = "<p>Replacement during initialization</p>"
            }
            coordinator.userContentController(controller, didReceive: message)
        }
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "contentChanged")
        controller.add(relay, name: "contentChanged")
        defer { controller.removeScriptMessageHandler(forName: "contentChanged") }
        await fulfillment(of: [ready], timeout: 15)
        let oldMessage = try XCTUnwrap(retainedOriginal)
        XCTAssertEqual(content, "<p>Replacement during initialization</p>")
        coordinator.userContentController(controller, didReceive: oldMessage)
        XCTAssertEqual(content, "<p>Replacement during initialization</p>")
        let rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(rendered, content)
    }



    @MainActor
    func testEditorRejectsMessagesFromAnotherWebView() async throws {
        let owner = WKWebView(frame: .zero)
        var content = "<p>Current</p>"
        let unexpectedWrite = expectation(description: "Retired editor binding is untouched")
        unexpectedWrite.isInverted = true
        let coordinator = EditorWebSurface(
            htmlContent: Binding(get: { content }, set: {
                content = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        let (source, messages) = try await captureBridgeMessages(for: coordinator)
        defer { source.stopLoading() }
        coordinator.webView = owner
        coordinator.lastContentFromJS = content
        coordinator.isEditorReady = true
        coordinator.userContentController(source.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "contentChanged" }))
        await fulfillment(of: [unexpectedWrite], timeout: 0.1)
        XCTAssertEqual(content, "<p>Current</p>")

        coordinator.isEditorReady = false
        coordinator.userContentController(source.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "editorReady" }))
        XCTAssertNil(coordinator.currentTheme, "A foreign readiness message cannot start initialization")
        XCTAssertFalse(coordinator.isEditorReady)
    }

    @MainActor
    func testEditorRejectsRetainedMessagesAfterDismantle() async throws {
        var content = "<p>Current</p>"
        let unexpectedWrite = expectation(description: "Retired editor binding is untouched")
        unexpectedWrite.isInverted = true
        let coordinator = EditorWebSurface(
            htmlContent: Binding(get: { content }, set: {
                content = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        let (webView, messages) = try await captureBridgeMessages(for: coordinator)
        defer { webView.stopLoading() }
        coordinator.webView = webView
        coordinator.lastContentFromJS = content
        coordinator.isEditorReady = true
        #if os(macOS)
        EditorWebSurface.dismantle(webView, coordinator: coordinator)
        #else
        EditorWebSurface.dismantle(webView, coordinator: coordinator)
        #endif
        for message in messages where message.name != "heightChanged" {
            coordinator.userContentController(webView.configuration.userContentController, didReceive: message)
        }
        await fulfillment(of: [unexpectedWrite], timeout: 0.1)
        XCTAssertEqual(content, "<p>Current</p>")
        XCTAssertNil(coordinator.webView)
        XCTAssertNil(coordinator.currentTheme)
    }



    @MainActor
    func testCoordinatorsRejectChildFrameMessagesInTheirOwnWebView() async throws {
        let unexpectedWrite = expectation(description: "Child frame cannot write editor or height bindings")
        unexpectedWrite.isInverted = true
        var content = "<p>Current</p>"
        var height: CGFloat = 10
        let editor = EditorWebSurface(
            htmlContent: Binding(get: { content }, set: {
                content = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        let renderer = HTMLContentView(htmlContent: content,
            contentHeight: Binding(get: { height }, set: {
                height = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        let (webView, messages) = try await captureBridgeMessages(for: editor, childFrame: true)
        defer { webView.stopLoading() }
        XCTAssertTrue(messages.allSatisfy { !$0.frameInfo.isMainFrame })
        XCTAssertTrue(messages.allSatisfy { $0.webView === webView })
        editor.webView = webView
        renderer.webView = webView
        let currentHeight = try await captureRenderedHeight(in: webView, coordinator: renderer, height: 400)
        let childHeight = try await captureChildFrameHeight(currentHeight.body, in: webView)
        XCTAssertFalse(childHeight.frameInfo.isMainFrame)
        XCTAssertTrue(childHeight.webView === webView)
        editor.lastContentFromJS = content
        editor.isEditorReady = true
        editor.userContentController(webView.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "contentChanged" }))
        renderer.userContentController(webView.configuration.userContentController, didReceive: childHeight)
        editor.isEditorReady = false
        editor.userContentController(webView.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "editorReady" }))
        await fulfillment(of: [unexpectedWrite], timeout: 0.1)
        XCTAssertEqual(content, "<p>Current</p>")
        XCTAssertEqual(height, 10)
        XCTAssertFalse(editor.isEditorReady)
        XCTAssertNil(editor.currentTheme)
    }





    @MainActor
    private func captureRenderedHeight(in webView: WKWebView, coordinator: HTMLContentView.Coordinator,
        height: Int, theme: String = "light", excludingGeneration: String? = nil,
        afterLoad: (() -> Void)? = nil) async throws -> WKScriptMessage {
        let captured = expectation(description: "Production height envelope captured")
        captured.assertForOverFulfill = false
        let receiver = BridgeMessageCapture(captured) { message in
            guard message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any],
                  let generation = payload["generation"] as? String else { return false }
            return generation != excludingGeneration
        }
        webView.configuration.userContentController.add(receiver, name: "heightChanged")
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged") }
        coordinator.loadContentIfNeeded("<p style='height: \(height)px'>Measured</p>", theme: theme, in: webView)
        afterLoad?()
        await fulfillment(of: [captured], timeout: 15)
        return try XCTUnwrap(receiver.messages.first)
    }

    @MainActor
    private func captureChildFrameHeight(_ payload: Any, in webView: WKWebView) async throws -> WKScriptMessage {
        let captured = expectation(description: "Child-frame height envelope captured")
        let receiver = BridgeMessageCapture(captured) { !$0.frameInfo.isMainFrame }
        webView.configuration.userContentController.add(receiver, name: "heightChanged")
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "heightChanged") }
        let encodedPayload = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let source = "<script>window.webkit.messageHandlers.heightChanged.postMessage(\(encodedPayload));</script>"
        let encodedSource = String(decoding: try JSONSerialization.data(withJSONObject: source,
            options: .fragmentsAllowed), as: UTF8.self)
        _ = try await webView.evaluateJavaScript("""
            (() => {
                const frame = document.createElement('iframe');
                frame.srcdoc = \(encodedSource);
                document.body.appendChild(frame);
                return true;
            })()
            """)
        await fulfillment(of: [captured], timeout: 15)
        return try XCTUnwrap(receiver.messages.first)
    }

    @MainActor
    private func captureBridgeMessages(for coordinator: EditorWebSurface.Coordinator,
        childFrame: Bool = false) async throws -> (WKWebView, [WKScriptMessage]) {
        let captured = expectation(description: "Real WebKit bridge messages captured")
        captured.expectedFulfillmentCount = 3
        let receiver = BridgeMessageCapture(captured)
        let configuration = WKWebViewConfiguration()
        let names = ["contentChanged", "editorReady", "heightChanged"]
        for name in names { configuration.userContentController.add(receiver, name: name) }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer {
            for name in names { configuration.userContentController.removeScriptMessageHandler(forName: name) }
        }
        let script = """
            <script>
            window.webkit.messageHandlers.contentChanged.postMessage({
                bridgeGeneration: '\(coordinator.bridgeGeneration)',
                contentGeneration: '\(coordinator.contentGeneration)', html: '<p>Retired</p>'
            });
            window.webkit.messageHandlers.editorReady.postMessage({ bridgeGeneration: '\(coordinator.bridgeGeneration)' });
            window.webkit.messageHandlers.heightChanged.postMessage(123);
            </script>
            """
        let html = childFrame ? "<iframe srcdoc=\"\(script)\"></iframe>" : script
        webView.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [captured], timeout: 15)
        XCTAssertEqual(receiver.messages.count, 3)
        return (webView, receiver.messages)
    }

    @MainActor
    private final class EditorMessageRelay: NSObject, WKScriptMessageHandler, @unchecked Sendable {
        let receive: (WKUserContentController, WKScriptMessage) -> Void

        init(_ receive: @escaping (WKUserContentController, WKScriptMessage) -> Void) {
            self.receive = receive
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            receive(controller, message)
        }
    }

    @MainActor
    private final class BridgeMessageCapture: NSObject, WKScriptMessageHandler, @unchecked Sendable {
        let captured: XCTestExpectation
        let acceptsMessage: (WKScriptMessage) -> Bool
        var messages: [WKScriptMessage] = []

        init(_ captured: XCTestExpectation, acceptsMessage: @escaping (WKScriptMessage) -> Bool = { _ in true }) {
            self.captured = captured
            self.acceptsMessage = acceptsMessage
        }

        func userContentController(_ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage) {
            guard acceptsMessage(message) else { return }
            messages.append(message)
            captured.fulfill()
        }
    }

    @MainActor
    private final class MountedEditorView<Content: View> {
        #if os(macOS)
        let host: NSHostingView<Content?>
        let window: NSWindow
        #else
        let host: UIHostingController<Content?>
        let window: UIWindow
        weak var previousKeyWindow: UIWindow?
        #endif

        init(_ editor: Content) {
            #if os(macOS)
            host = NSHostingView(rootView: Optional(editor))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #else
            host = UIHostingController(rootView: Optional(editor))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
            if let scene {
                window = UIWindow(windowScene: scene)
                window.frame = scene.coordinateSpace.bounds
            } else {
                window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
            }
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            #endif
        }

        func replace(_ editor: Content) {
            host.rootView = editor
            #if os(macOS)
            host.layoutSubtreeIfNeeded()
            #else
            host.view.layoutIfNeeded()
            #endif
        }

        var webView: WKWebView? {
            #if os(macOS)
            var pending: [NSView] = [host]
            #else
            var pending: [UIView] = [host.view]
            #endif
            while let view = pending.popLast() {
                if let webView = view as? WKWebView { return webView }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        func close() {
            // Remove the SwiftUI graph as well as the window. Keeping a host
            // with its old root alive does not guarantee representable teardown.
            host.rootView = nil
            #if os(macOS)
            host.layoutSubtreeIfNeeded()
            window.contentView = nil
            window.close()
            #else
            host.view.layoutIfNeeded()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            #endif
        }
    }

    @MainActor
    func testHostedEditorNormalizesBeforeReadinessAndTracksImmediateEdit() async throws {
        let ready = expectation(description: "Editor ready after content initialization")
        let edited = expectation(description: "Immediate editor change reaches draft")
        let store = RichTextEditorSheetDraftStore(htmlContent: "<p>Original</p>")
        let context = EditorContext()
        let editor = EditorWebSurface(
            htmlContent: Binding(
                get: { store.draftHTMLContent },
                set: { html in
                    store.syncFromEditor(html)
                    if html == "<h2>Original</h2><p></p>" { edited.fulfill() }
                }
            ),
            editorContext: context,
            onEditorReady: {
                store.beginTrackingEdits()
                ready.fulfill()
            }
        )
        #if os(macOS)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        #else
        // Package-shaped XCTest runners do not install a scene delegate. Their
        // UIKit window still mounts the real hosting controller and WKWebView.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        }
        let host = UIHostingController(rootView: editor)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        #endif
        await fulfillment(of: [ready], timeout: 15)
        XCTAssertEqual(store.originalHTMLContent, "<p>Original</p>")
        XCTAssertFalse(store.hasEdits)
        let webView = try XCTUnwrap(context.webView)
        webView.evaluateJavaScript("window.toggleHeading(2); true") { _, error in
            XCTAssertNil(error)
        }
        await fulfillment(of: [edited], timeout: 2)
        XCTAssertTrue(store.hasEdits)
        XCTAssertEqual(store.commit(), "<h2>Original</h2><p></p>")
    }

    @MainActor
    func testHostedEditorRoundTripsRubyAndKeepsAdjacentText() async throws {
        let ready = expectation(description: "Editor ready")
        let store = RichTextEditorSheetDraftStore(
            htmlContent: "<p><ruby>漢<rt>かん</rt><rp>(</rp><rp>)</rp></ruby>語</p>"
        )
        let context = EditorContext()
        let editor = EditorWebSurface(
            htmlContent: Binding(
                get: { store.draftHTMLContent },
                set: { store.syncFromEditor($0) }
            ),
            editorContext: context,
            onEditorReady: {
                store.beginTrackingEdits()
                ready.fulfill()
            }
        )
        #if os(macOS)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        #else
        // Package-shaped XCTest runners do not install a scene delegate. Their
        // UIKit window still mounts the real hosting controller and WKWebView.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        }
        let host = UIHostingController(rootView: editor)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        #endif
        await fulfillment(of: [ready], timeout: 15)

        let content = try await context.webView?.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(content, "<p><ruby>漢<rt>かん</rt><rp>(</rp><rp>)</rp></ruby>語</p>")

        let adjacentText = expectation(description: "Adjacent text survives ruby edit")
        context.webView?.evaluateJavaScript(
            "window.setContent('<p><ruby>漢<rt>かん</rt></ruby>語</p>'); window.getContent();"
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? String, "<p><ruby>漢<rt>かん</rt></ruby>語</p>")
            adjacentText.fulfill()
        }
        await fulfillment(of: [adjacentText], timeout: 2)
    }
}
#endif
