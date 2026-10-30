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

/// Preserve the v4 read-only renderer's document/binding regression coverage
/// while the editable surface moves from WKWebView to native text views.
final class HTMLContentViewLifetimeTests: XCTestCase {
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
    func testHTMLContentRejectsForeignAndRetainedHeightMessages() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        defer { webView.stopLoading() }
        var height: CGFloat = 10
        var heightDelivery: (() -> Void)?
        let coordinator = HTMLContentView(htmlContent: "<p>Current</p>",
            contentHeight: Binding(get: { height }, set: {
                height = $0
                heightDelivery?()
            })
        ).makeCoordinator()
        coordinator.webView = webView
        let message = try await captureRenderedHeight(in: webView, coordinator: coordinator, height: 400)
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
        XCTAssertEqual(height, 400, "The live original WebView still publishes its height")
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
    func testHTMLContentRejectsPreviousDocumentHeightInReusedWebView() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        defer { webView.stopLoading() }
        var original: CGFloat = 0
        var replacement: CGFloat = 0
        let coordinator = HTMLContentView(htmlContent: "",
            contentHeight: Binding(get: { original }, set: { original = $0 })
        ).makeCoordinator()
        coordinator.webView = webView
        let first = try await captureRenderedHeight(in: webView, coordinator: coordinator, height: 400)
        coordinator.userContentController(webView.configuration.userContentController, didReceive: first)
        XCTAssertEqual(original, 400)
        let firstGeneration = try XCTUnwrap((first.body as? [String: Any])?["generation"] as? String)

        coordinator.parent = HTMLContentView(htmlContent: "",
            contentHeight: Binding(get: { replacement }, set: { replacement = $0 }))
        let second = try await captureRenderedHeight(in: webView, coordinator: coordinator,
            height: 600, excludingGeneration: firstGeneration, afterLoad: {
                coordinator.userContentController(webView.configuration.userContentController, didReceive: first)
                XCTAssertEqual(replacement, 0, "Reload must retire the old generation before WebKit completes")
            })
        XCTAssertTrue(first.webView === second.webView)
        XCTAssertTrue(first.frameInfo.isMainFrame && second.frameInfo.isMainFrame)
        coordinator.userContentController(webView.configuration.userContentController, didReceive: first)
        XCTAssertEqual(replacement, 0, "A queued height from the previous document cannot reach the new binding")
        coordinator.userContentController(webView.configuration.userContentController, didReceive: second)
        XCTAssertEqual(replacement, 600)
        XCTAssertEqual(original, 400)

        // A theme-only reload also replaces the document and its height generation.
        let secondGeneration = try XCTUnwrap((second.body as? [String: Any])?["generation"] as? String)
        let third = try await captureRenderedHeight(in: webView, coordinator: coordinator,
            height: 600, theme: "dark", excludingGeneration: secondGeneration)
        replacement = 0
        coordinator.userContentController(webView.configuration.userContentController, didReceive: second)
        XCTAssertEqual(replacement, 0)
        coordinator.userContentController(webView.configuration.userContentController, didReceive: third)
        XCTAssertEqual(replacement, 600)

        replacement = 0
        coordinator.loadContentIfNeeded("<p style='height: 600px'>Measured</p>", theme: "dark", in: webView)
        coordinator.userContentController(webView.configuration.userContentController, didReceive: third)
        XCTAssertEqual(replacement, 600, "An identical render must retain its valid generation")
        coordinator.retireRender()
        replacement = 0
        coordinator.userContentController(webView.configuration.userContentController, didReceive: third)
        XCTAssertEqual(replacement, 0, "Retirement invalidates the envelope even while the WebView is retained")
    }

    @MainActor
    func testHostedHTMLContentKeepsDocumentAcrossHeightOnlyUpdates() async throws {
        let ready = expectation(description: "Initial rendered height")
        var height: CGFloat = 0
        let html = "<p style='height: 400px'>Measured</p>"
        let binding = Binding(get: { height }, set: { value in
            if height == 0 && value > 0 { ready.fulfill() }
            height = value
        })
        let mounted = MountedEditorView(HTMLContentView(htmlContent: html, contentHeight: binding))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(mounted.webView)
        _ = try await webView.evaluateJavaScript("window.heightDocumentMarker = 'original'; true")
        let delivered = expectation(description: "Existing document reports to replacement height binding")
        var replacement: CGFloat = 0
        var didDeliver = false
        mounted.replace(HTMLContentView(htmlContent: html,
            contentHeight: Binding(get: { replacement }, set: {
                replacement = $0
                if !didDeliver {
                    didDeliver = true
                    delivered.fulfill()
                }
            })))
        // Production must request a measurement for the new binding; the test
        // never calls reportHeight or changes the unchanged document's layout.
        await fulfillment(of: [delivered], timeout: 5)
        let marker = try await webView.evaluateJavaScript("window.heightDocumentMarker") as? String
        XCTAssertEqual(marker, "original", "Identical HTML/theme must retain the current document")
        XCTAssertEqual(replacement, 400)
        XCTAssertTrue(mounted.webView === webView)
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

}
#endif
