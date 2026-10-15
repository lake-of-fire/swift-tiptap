import Testing
@testable import TipTapSwift

@MainActor
@Test func draftStoreStartsWithOriginalHTML() {
    let original = "<p>Start</p>"
    let store = RichTextEditorSheetDraftStore(htmlContent: original)

    #expect(store.originalHTMLContent == original)
    #expect(store.draftHTMLContent == original)
    #expect(store.hasEdits == false)
}

@MainActor
@Test func cancelRestoresOriginalHTMLAfterEdits() {
    let original = "<p>Original</p>"
    let store = RichTextEditorSheetDraftStore(htmlContent: original)

    store.draftHTMLContent = "<p>Edited</p>"
    store.cancel()

    #expect(store.draftHTMLContent == original)
    #expect(store.originalHTMLContent == original)
    #expect(store.hasEdits == false)
}

@MainActor
@Test func commitReturnsLatestDraftWithoutChangingOriginal() {
    let original = "<p>Original</p>"
    let store = RichTextEditorSheetDraftStore(htmlContent: original)

    store.beginTrackingEditsForTests()
    store.draftHTMLContent = "<p>First edit</p>"
    store.draftHTMLContent = "<p>Final edit</p>"

    let committed = store.commit()

    #expect(committed == "<p>Final edit</p>")
    #expect(store.originalHTMLContent == original)
    #expect(store.draftHTMLContent == "<p>Final edit</p>")
    #expect(store.hasEdits == true)
}

@MainActor
@Test func commitCanNormalizeEditorBoilerplateHTMLForPlainTextFields() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "plain definition")

    store.syncFromEditor("<p>plain definition</p>")

    let committed = store.commit(normalizingWith: { html in
        html == "<p>plain definition</p>" ? "plain definition" : html
    })

    #expect(committed == "plain definition")
    #expect(store.draftHTMLContent == "<p>plain definition</p>")
}

@MainActor
@Test func firstEditorSyncBecomesBaselineWithoutCountingAsAnEdit() {
    let source = "<ruby>漢<rt>かん</rt></ruby>"
    let normalized = "<p><ruby>漢<rt>かん</rt></ruby></p>"
    let store = RichTextEditorSheetDraftStore(htmlContent: source)

    store.syncFromEditor(normalized)

    #expect(store.originalHTMLContent == source)
    #expect(store.draftHTMLContent == normalized)
    #expect(store.hasEdits == false)
}

@MainActor
@Test func unchangedBodyCommitsExactSourceAfterEditorNormalization() {
    let source = "<ruby>漢<rt>かん</rt></ruby>"
    let store = RichTextEditorSheetDraftStore(htmlContent: source)

    store.syncFromEditor("<p><ruby>漢<rt>かん</rt></ruby></p>")
    store.beginTrackingEdits()

    #expect(store.hasEdits == false)
    #expect(store.commit() == source)
}

@MainActor
@Test func cancelRestoresExactSourceAndClearsNormalizedDraftEdit() {
    let source = "<ruby>漢<rt>かん</rt></ruby>"
    let store = RichTextEditorSheetDraftStore(htmlContent: source)

    store.syncFromEditor("<p><ruby>漢<rt>かん</rt></ruby></p>")
    store.beginTrackingEdits()
    store.syncFromEditor("<p><ruby>漢<rt>かん</rt></ruby>語</p>")
    #expect(store.hasEdits)

    store.cancel()

    #expect(store.draftHTMLContent == source)
    #expect(store.commit() == source)
    #expect(store.hasEdits == false)
}

@MainActor
@Test func subsequentEditorSyncsStillCountAsEdits() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "")

    store.syncFromEditor("<p></p>")
    store.beginTrackingEditsForTests()
    store.syncFromEditor("<p>Hello</p>")

    #expect(store.originalHTMLContent == "")
    #expect(store.draftHTMLContent == "<p>Hello</p>")
    #expect(store.hasEdits == true)
}

@MainActor
@Test func firstInteractiveEditIsTrackedImmediately() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "<p>Original</p>")
    store.beginTrackingEdits()
    store.syncFromEditor("<p>Quick edit</p>")
    store.beginTrackingEdits() // A repeated readiness event cannot absorb the edit.
    #expect(store.hasEdits)
    #expect(store.originalHTMLContent == "<p>Original</p>")
    #expect(store.commit() == "<p>Quick edit</p>")
}

#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import WebKit
import XCTest

final class RichTextEditorReadinessTests: XCTestCase {
    @MainActor
    func testHostedEditorUsesLatestBindingValueBeforeReadiness() async throws {
        let ready = expectation(description: "Latest content initialized")
        var content = "<p>Original</p>"
        let context = EditorContext()
        let editor = RichTextEditorView(
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
        let mounted = MountedEditorView(RichTextEditorView(
            htmlContent: Binding(get: { original }, set: { original = $0 }),
            editorContext: context,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        #if os(iOS)
        let contentView = try XCTUnwrap(webView.scrollView.subviews.first {
            let name = NSStringFromClass(type(of: $0))
            return name.hasPrefix("WKContent") || name.hasPrefix("_TipTapContent_")
        })
        let originalAccessory = try XCTUnwrap(contentView.inputAccessoryView)
        #endif

        mounted.replace(RichTextEditorView(
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
            rendered = try await webView.evaluateJavaScript("window.getContent()") as? String
            if rendered == "<p>Replacement</p>" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        XCTAssertEqual(rendered, "<p>Replacement</p>")
        XCTAssertNil(context.webView, "The previous command context must lose its editor")
        XCTAssertTrue(replacementContext.webView === webView, "The new context must reuse the original editor")
        #if os(iOS)
        let accessory = try XCTUnwrap(contentView.inputAccessoryView)
        XCTAssertTrue(accessory is FormattingAccessoryView)
        XCTAssertFalse(accessory === originalAccessory)
        #endif

        replacementContext.toggleHeading(level: 2)
        await fulfillment(of: [edited], timeout: 2)
        XCTAssertEqual(original, "<p>Original</p>")
        XCTAssertEqual(replacement, "<h2>Replacement</h2><p></p>")
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? RichTextEditorView.Coordinator)
        #if os(macOS)
        RichTextEditorView.dismantleNSView(webView, coordinator: coordinator)
        #else
        RichTextEditorView.dismantleUIView(webView, coordinator: coordinator)
        #endif
        XCTAssertNil(replacementContext.webView)
    }

    @MainActor
    func testHostedHTMLContentWritesReplacementHeightBinding() async throws {
        let firstHeight = expectation(description: "Original HTML measured")
        let replacementHeight = expectation(description: "Replacement HTML measured")
        var original: CGFloat = 0
        var replacement: CGFloat = 0
        let mounted = MountedEditorView(HTMLContentView(
            htmlContent: "<p>Original</p>",
            contentHeight: Binding(get: { original }, set: { height in
                if original == 0 && height > 0 { firstHeight.fulfill() }
                original = height
            })
        ))
        defer { mounted.close() }
        await fulfillment(of: [firstHeight], timeout: 15)
        let webView = try XCTUnwrap(mounted.webView)
        let measuredOriginal = original

        mounted.replace(HTMLContentView(
            htmlContent: "<p style='height: 600px'>Replacement</p>",
            contentHeight: Binding(get: { replacement }, set: { height in
                if replacement < 600 && height >= 600 { replacementHeight.fulfill() }
                replacement = height
            })
        ))
        await fulfillment(of: [replacementHeight], timeout: 15)
        XCTAssertTrue(mounted.webView === webView)
        XCTAssertGreaterThanOrEqual(replacement, 600)
        XCTAssertEqual(original, measuredOriginal)
    }

    @MainActor
    func testEditorRejectsMessagesFromAnotherWebView() async throws {
        let (source, messages) = try await captureBridgeMessages()
        defer { source.stopLoading() }
        let owner = WKWebView(frame: .zero)
        var content = "<p>Current</p>"
        let unexpectedWrite = expectation(description: "Retired editor binding is untouched")
        unexpectedWrite.isInverted = true
        let coordinator = RichTextEditorView(
            htmlContent: Binding(get: { content }, set: {
                content = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        coordinator.webView = owner
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
        let (webView, messages) = try await captureBridgeMessages()
        defer { webView.stopLoading() }
        var content = "<p>Current</p>"
        let unexpectedWrite = expectation(description: "Retired editor binding is untouched")
        unexpectedWrite.isInverted = true
        let coordinator = RichTextEditorView(
            htmlContent: Binding(get: { content }, set: {
                content = $0
                unexpectedWrite.fulfill()
            })
        ).makeCoordinator()
        coordinator.webView = webView
        coordinator.isEditorReady = true
        #if os(macOS)
        RichTextEditorView.dismantleNSView(webView, coordinator: coordinator)
        #else
        RichTextEditorView.dismantleUIView(webView, coordinator: coordinator)
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
    func testHTMLContentRejectsForeignAndRetainedHeightMessages() async throws {
        let (webView, messages) = try await captureBridgeMessages()
        defer { webView.stopLoading() }
        let message = try XCTUnwrap(messages.first { $0.name == "heightChanged" })
        var height: CGFloat = 10
        var heightDelivery: (() -> Void)?
        let coordinator = HTMLContentView(htmlContent: "<p>Current</p>",
            contentHeight: Binding(get: { height }, set: {
                height = $0
                heightDelivery?()
            })
        ).makeCoordinator()
        let owner = WKWebView(frame: .zero)
        coordinator.webView = owner
        let foreignWrite = expectation(description: "Foreign height is ignored")
        foreignWrite.isInverted = true
        heightDelivery = { foreignWrite.fulfill() }
        coordinator.userContentController(webView.configuration.userContentController, didReceive: message)
        await fulfillment(of: [foreignWrite], timeout: 0.1)
        XCTAssertEqual(height, 10, "A different WebView cannot publish a height")

        coordinator.webView = webView
        let liveWrite = expectation(description: "Live height is delivered")
        heightDelivery = { liveWrite.fulfill() }
        coordinator.userContentController(webView.configuration.userContentController, didReceive: message)
        await fulfillment(of: [liveWrite], timeout: 2)
        XCTAssertEqual(height, 123, "The live original WebView still publishes its height")
        #if os(macOS)
        HTMLContentView.dismantleNSView(webView, coordinator: coordinator)
        #else
        HTMLContentView.dismantleUIView(webView, coordinator: coordinator)
        #endif
        height = 20
        let retiredWrite = expectation(description: "Retired height is ignored")
        retiredWrite.isInverted = true
        heightDelivery = { retiredWrite.fulfill() }
        coordinator.userContentController(webView.configuration.userContentController, didReceive: message)
        await fulfillment(of: [retiredWrite], timeout: 0.1)
        XCTAssertEqual(height, 20, "A retained callback cannot update a dismantled view")
    }

    @MainActor
    func testCoordinatorsRejectChildFrameMessagesInTheirOwnWebView() async throws {
        let (webView, messages) = try await captureBridgeMessages(childFrame: true)
        defer { webView.stopLoading() }
        XCTAssertTrue(messages.allSatisfy { !$0.frameInfo.isMainFrame })
        XCTAssertTrue(messages.allSatisfy { $0.webView === webView })
        let unexpectedWrite = expectation(description: "Child frame cannot write editor or height bindings")
        unexpectedWrite.isInverted = true
        var content = "<p>Current</p>"
        var height: CGFloat = 10
        let editor = RichTextEditorView(
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
        editor.webView = webView
        renderer.webView = webView
        editor.isEditorReady = true
        editor.userContentController(webView.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "contentChanged" }))
        renderer.userContentController(webView.configuration.userContentController,
            didReceive: try XCTUnwrap(messages.first { $0.name == "heightChanged" }))
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
    private func captureBridgeMessages(childFrame: Bool = false) async throws -> (WKWebView, [WKScriptMessage]) {
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
            window.webkit.messageHandlers.contentChanged.postMessage('<p>Retired</p>');
            window.webkit.messageHandlers.editorReady.postMessage(true);
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
    private final class BridgeMessageCapture: NSObject, WKScriptMessageHandler, @unchecked Sendable {
        let captured: XCTestExpectation
        var messages: [WKScriptMessage] = []

        init(_ captured: XCTestExpectation) {
            self.captured = captured
        }

        func userContentController(_ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage) {
            messages.append(message)
            captured.fulfill()
        }
    }

    @MainActor
    private final class MountedEditorView<Content: View> {
        #if os(macOS)
        let host: NSHostingView<Content>
        let window: NSWindow
        #else
        let host: UIHostingController<Content>
        let window: UIWindow
        weak var previousKeyWindow: UIWindow?
        #endif

        init(_ editor: Content) {
            #if os(macOS)
            host = NSHostingView(rootView: editor)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #else
            host = UIHostingController(rootView: editor)
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
            #if os(macOS)
            window.contentView = nil
            window.close()
            #else
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
        let editor = RichTextEditorView(
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
        let editor = RichTextEditorView(
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
