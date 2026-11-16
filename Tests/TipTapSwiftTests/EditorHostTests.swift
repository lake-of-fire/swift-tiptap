#if os(iOS) || os(macOS)
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import TipTapSwift
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Requires a real iOS/macOS host. Portable qualification does not run these
/// tests, emulate WebKit, or establish App Store suitability.
final class EditorHostTests: XCTestCase {
    @MainActor
    func testDelayedAcknowledgmentCannotCrossSameHTMLBaselineReplacement() async throws {
        let ready = expectation(description: "Local page ready for delayed reply")
        var html = "<p>同じ</p>"
        let binding = Binding(get: { html }, set: { html = $0 })
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: binding, documentID: "stable", editorContext: context,
            profile: .localWriting, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? RichTextEditorView.Coordinator)
        let owner: [String: Any] = [
            "contentContextID": UUID().uuidString, "documentID": UUID().uuidString,
            "editorID": UUID().uuidString, "pageID": UUID().uuidString,
            "admissionGeneration": 0, "baselineGeneration": 0
        ]
        let namespace = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: [
            "version": 1, "operation": "activate", "owner": owner, "namespace": namespace, "expectedHTML": html
        ])
        // Delay only the public native call's return value. The real receiver
        // has executed; its WebKit promise reply remains pending across a real
        // native baseline replacement with identical HTML.
        _ = try await webView.evaluateJavaScript("""
            (() => {
                const stringify = JSON.stringify
                const request = window.localWritingRequest
                window.localWritingRequest = value => ({ delayedBridgeReply: true, actual: request(value) })
                JSON.stringify = function(value, ...rest) {
                    if (!value?.delayedBridgeReply) return stringify.call(JSON, value, ...rest)
                    return new Promise(resolve => {
                        window.releaseDelayedBridgeReply = () => {
                            JSON.stringify = stringify
                            window.localWritingRequest = request
                            resolve(stringify(value.actual))
                        }
                    })
                }
            })()
            """)
        let pending = Task { try await context.localWritingRequest(request) }
        let deadline = Date().addingTimeInterval(5)
        var waiting = false
        while !waiting, Date() < deadline {
            waiting = try await webView.evaluateJavaScript("typeof window.releaseDelayedBridgeReply === 'function'") as? Bool == true
            if !waiting { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(waiting)
        coordinator.replaceContentIfNeeded(html, force: true)
        _ = try await webView.evaluateJavaScript("window.releaseDelayedBridgeReply?.()")
        do {
            _ = try await pending.value
            XCTFail("Old native reply crossed the replacement content generation")
        } catch {}
        let snapshotRequest = try JSONSerialization.data(withJSONObject: [
            "version": 1, "operation": "snapshot", "owner": owner, "namespace": namespace
        ])
        let response = try await context.localWritingRequest(snapshotRequest)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(value["status"] as? String, "unavailable")
        XCTAssertEqual(value["reason"] as? String, "editorUnavailable")
        let actual = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(actual, html)
    }

    @MainActor
    func testAcknowledgedLocalBridgeUsesArgumentsAndRetiresSameHTMLContext() async throws {
        let ready = expectation(description: "Acknowledged local page ready")
        var html = "<p>か\u{3099}𠮷 ' \\</p>"
        let binding = Binding(get: { html }, set: { html = $0 })
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: binding, documentID: "A", editorContext: context,
            profile: .localWriting, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let owner: [String: Any] = [
            "contentContextID": UUID().uuidString, "documentID": UUID().uuidString,
            "editorID": UUID().uuidString, "pageID": UUID().uuidString,
            "admissionGeneration": 0, "baselineGeneration": 0
        ]
        let namespace = UUID().uuidString
        let request = try JSONSerialization.data(withJSONObject: [
            "version": 1, "operation": "activate", "owner": owner, "namespace": namespace,
            "expectedHTML": html, "initialSelection": ["lowerBound": 0, "upperBound": 2]
        ])
        let data = try await context.localWritingRequest(request)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(reply["status"] as? String, "snapshot")
        let snapshot = try XCTUnwrap(reply["snapshot"] as? [String: Any])
        let document = try XCTUnwrap(snapshot["document"] as? [String: Any])
        XCTAssertEqual(document["plainText"] as? String, "か\u{3099}𠮷 ' \\")
        let editable = try await webView.evaluateJavaScript("document.querySelector('.tiptap').contentEditable") as? String
        XCTAssertEqual(editable, "false")

        // A replacement owner can display identical HTML. The old context must
        // lose the native capability even though string equality cannot tell.
        let replacement = EditorContext()
        mounted.replace(RichTextEditorHost(htmlContent: binding, documentID: "B",
            editorContext: replacement, profile: .localWriting))
        let deadline = Date().addingTimeInterval(5)
        while replacement.webView !== webView, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(replacement.webView === webView)
        XCTAssertNil(context.webView)
        XCTAssertNil(context.localWritingSnapshotJSON)
        do {
            _ = try await context.localWritingRequest(request)
            XCTFail("Retired context accepted a local bridge request")
        } catch {}
        let currentHTML = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(currentHTML, html)
    }

    @MainActor
    func testLocalWritingUsesEphemeralStorageAndNeverInstallsAccessoryOnContextChange() async throws {
        let ready = expectation(description: "Local page initialized under CSP")
        var html = "<p>A  B\tC\nD</p>"
        let binding = Binding(get: { html }, set: { html = $0 })
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: binding, editorContext: context, profile: .localWriting,
            onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? RichTextEditorView.Coordinator)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertEqual(webView.url?.lastPathComponent, "tiptap-local-writing.html")
        XCTAssertEqual(html, "<p>A  B\tC\nD</p>")
        let profile = try await webView.evaluateJavaScript("window.__tipTapContentProfile") as? String
        XCTAssertEqual(profile, "localWriting")
        #if os(iOS)
        XCTAssertNil(coordinator.accessoryView)
        assertNoPrivateAccessory(in: webView)
        #endif

        let replacementContext = EditorContext()
        mounted.replace(RichTextEditorHost(
            htmlContent: binding, editorContext: replacementContext, profile: .localWriting
        ))
        let deadline = Date().addingTimeInterval(5)
        while replacementContext.webView !== webView, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(replacementContext.webView === webView)
        XCTAssertNil(context.webView)
        #if os(iOS)
        XCTAssertNil(coordinator.accessoryView)
        assertNoPrivateAccessory(in: webView)
        #endif
    }

    @MainActor
    func testChangingHostProfileReplacesWebViewAndRetiresPreviousContextOwner() async throws {
        let standardReady = expectation(description: "Standard page initialized")
        var html = "<p>Stable document</p>"
        let binding = Binding(get: { html }, set: { html = $0 })
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: binding, documentID: "document", editorContext: context,
            onEditorReady: { standardReady.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [standardReady], timeout: 15)
        let original = try XCTUnwrap(context.webView)
        let previousCoordinator = try XCTUnwrap(original.navigationDelegate as? RichTextEditorView.Coordinator)
        XCTAssertTrue(original.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(original.url?.lastPathComponent, "tiptap-editor.html")
        #if os(iOS)
        XCTAssertNotNil(previousCoordinator.accessoryView)
        #endif

        let localReady = expectation(description: "Replacement local page initialized")
        mounted.replace(RichTextEditorHost(
            htmlContent: binding, documentID: "document", editorContext: context,
            profile: .localWriting, onEditorReady: { localReady.fulfill() }
        ))
        await fulfillment(of: [localReady], timeout: 15)
        let replacement = try XCTUnwrap(context.webView)
        XCTAssertFalse(original === replacement)
        XCTAssertNil(previousCoordinator.webView)
        XCTAssertFalse(replacement.configuration.websiteDataStore.isPersistent)
        let content = try await replacement.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(content, "<p>Stable document</p>")
        let undo = try await replacement.evaluateJavaScript("window.undo()") as? Bool
        XCTAssertEqual(undo, false)
        #if os(iOS)
        assertNoPrivateAccessory(in: replacement)
        #endif
    }

    @MainActor
    func testLocalPageCSPRejectsNetworkSubresourcesAndConnectRequests() async throws {
        let ready = expectation(description: "CSP page initialized")
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: .constant("<p>Local</p>"), editorContext: context,
            profile: .localWriting, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let result = try await webView.callAsyncJavaScript("""
            const violations = []
            const receive = event => violations.push(event.effectiveDirective)
            document.addEventListener('securitypolicyviolation', receive)
            const elements = []
            for (const [name, path] of [['script', 'script.js'], ['img', 'image.png'], ['iframe', 'frame.html']]) {
                const element = document.createElement(name)
                element.src = `https://editor-policy-test.invalid/${path}`
                elements.push(element)
                document.body.appendChild(element)
            }
            let fetchRejected = false
            await fetch('https://editor-policy-test.invalid/connect').catch(() => { fetchRejected = true })
            const deadline = Date.now() + 2000
            while (new Set(violations).size < 4 && Date.now() < deadline) {
                await new Promise(resolve => setTimeout(resolve, 10))
            }
            document.removeEventListener('securitypolicyviolation', receive)
            for (const element of elements) element.remove()
            return { violations, fetchRejected }
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let violations = try XCTUnwrap(result?["violations"] as? [String])
        XCTAssertTrue(violations.contains("connect-src"))
        XCTAssertTrue(violations.contains("img-src"))
        XCTAssertTrue(violations.contains { $0.hasPrefix("script-src") })
        XCTAssertTrue(violations.contains("frame-src"))
        XCTAssertEqual(result?["fetchRejected"] as? Bool, true)
        let content = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(content, "<p>Local</p>")
    }

    @MainActor
    func testLocalPageCancelsProgrammaticMainFrameNetworkNavigation() async throws {
        let ready = expectation(description: "Local editor initialized")
        let context = EditorContext()
        let mounted = MountedHost(RichTextEditorHost(
            htmlContent: .constant("<p>Retained</p>"), editorContext: context,
            profile: .localWriting, onEditorReady: { ready.fulfill() }
        ))
        defer { mounted.close() }
        await fulfillment(of: [ready], timeout: 15)
        let webView = try XCTUnwrap(context.webView)
        let coordinator = try XCTUnwrap(webView.navigationDelegate as? RichTextEditorView.Coordinator)
        let originalURL = webView.url
        let refused = expectation(description: "Production delegate refuses network navigation")
        let probe = NavigationProbe(coordinator: coordinator) { policy in
            XCTAssertEqual(policy, .cancel)
            refused.fulfill()
        }
        webView.navigationDelegate = probe
        defer { webView.navigationDelegate = coordinator }
        webView.load(URLRequest(url: try XCTUnwrap(URL(string: "https://editor-policy-test.invalid/navigation"))))
        await fulfillment(of: [refused], timeout: 5)
        XCTAssertEqual(webView.url, originalURL)
    }

    #if os(iOS)
    @MainActor
    private func assertNoPrivateAccessory(in webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(webView.scrollView.subviews.contains {
            NSStringFromClass(type(of: $0)).hasPrefix("_TipTapContent_")
        }, file: file, line: line)
    }
    #endif

    @MainActor
    private final class NavigationProbe: NSObject, WKNavigationDelegate, @unchecked Sendable {
        let coordinator: RichTextEditorView.Coordinator
        let receive: (WKNavigationActionPolicy) -> Void

        init(coordinator: RichTextEditorView.Coordinator, receive: @escaping (WKNavigationActionPolicy) -> Void) {
            self.coordinator = coordinator
            self.receive = receive
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            coordinator.webView(webView, decidePolicyFor: navigationAction) { policy in
                self.receive(policy)
                decisionHandler(policy)
            }
        }
    }

    @MainActor
    private final class MountedHost<Content: View> {
        #if os(macOS)
        let host: NSHostingView<Content>
        let window: NSWindow
        #else
        let host: UIHostingController<Content>
        let window: UIWindow
        weak var previousKeyWindow: UIWindow?
        #endif

        init(_ content: Content) {
            #if os(macOS)
            host = NSHostingView(rootView: content)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #else
            host = UIHostingController(rootView: content)
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

        func replace(_ content: Content) {
            host.rootView = content
            #if os(macOS)
            host.layoutSubtreeIfNeeded()
            #else
            host.view.layoutIfNeeded()
            #endif
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
