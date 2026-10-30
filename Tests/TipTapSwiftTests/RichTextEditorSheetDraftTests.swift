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

    store.beginTrackingEdits()
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
    store.beginTrackingEdits()
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

@MainActor
@Test func titleOnlySavePublishesRenamedTitleAndExactOriginalRubyHTML() {
    let source = "before<ruby>漢<rt>かん</rt><rp>(</rp><rp>)</rp></ruby>語after"
    let store = RichTextEditorSheetDraftStore(htmlContent: source, title: "Original")
    store.syncFromEditor("<p>" + source + "</p>")
    store.beginTrackingEdits()
    #expect(!store.hasEdits)

    store.draftTitle = "Renamed"
    #expect(store.hasEdits)
    let saved = store.snapshotForSave()
    #expect(saved.title == "Renamed")
    // Title edits must not cause the editor's normalization to replace source.
    #expect(saved.html == source)

    let reopened = RichTextEditorSheetDraftStore(htmlContent: saved.html, title: saved.title)
    reopened.syncFromEditor("<p>" + source + "</p>")
    reopened.beginTrackingEdits()
    #expect(reopened.draftTitle == "Renamed")
    #expect(reopened.snapshotForSave() == saved)
    #expect(!reopened.hasEdits)
}

@MainActor
@Test func savedTitleAndBodyUseTheSameCurrentDraft() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "<p>Original</p>", title: "Original")
    store.beginTrackingEdits()
    store.draftTitle = "Updated"
    store.syncFromEditor("<p><ruby>漢<rt>かん</rt></ruby>語</p>")

    let saved = store.snapshotForSave()
    #expect(saved.title == "Updated")
    #expect(saved.html == "<p><ruby>漢<rt>かん</rt></ruby>語</p>")
    #expect(store.hasEdits)
}

@MainActor
@Test func cancellingRestoresTitleAndRubyBodyTogether() {
    let source = "<ruby>漢<rt>かん</rt></ruby>語"
    let store = RichTextEditorSheetDraftStore(htmlContent: source, title: "Original")
    store.syncFromEditor("<p>" + source + "</p>")
    store.beginTrackingEdits()
    store.draftTitle = "Unsaved title"
    store.syncFromEditor("<p>Unsaved body</p>")
    #expect(store.hasEdits)

    store.cancel()
    #expect(store.draftTitle == "Original")
    #expect(store.snapshotForSave().html == source)
    #expect(!store.hasEdits)
}

@MainActor
@Test func revertingTitleDoesNotTurnEditorNormalizationIntoAnEdit() {
    let source = "<ruby>漢<rt>かん</rt></ruby>語"
    let store = RichTextEditorSheetDraftStore(htmlContent: source, title: "Original")
    store.syncFromEditor("<p>" + source + "</p>")
    store.beginTrackingEdits()
    store.draftTitle = "Temporary"
    #expect(store.hasEdits)
    store.draftTitle = "Original"

    #expect(!store.hasEdits)
    #expect(store.snapshotForSave().html == source)
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

#if os(macOS) || os(iOS)
@MainActor
private final class HostedFormattingEditor {
    let store: RichTextEditorSheetDraftStore
    let context = EditorContext()
    let ready = XCTestExpectation(description: "Standalone editor ready")
#if os(macOS)
    let window: NSWindow
#else
    let window: UIWindow
    let previousKeyWindow: UIWindow?
#endif

    init(html: String) {
        store = RichTextEditorSheetDraftStore(htmlContent: html)
        let store = store
        let ready = ready
        let editor = RichTextEditorView(htmlContent: Binding(
            get: { store.draftHTMLContent }, set: { store.syncFromEditor($0) }
        ), placeholder: "Test placeholder", editorContext: context, onEditorReady: {
            store.beginTrackingEdits()
            ready.fulfill()
        })
#if os(macOS)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: editor)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
#else
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKeyWindow = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 600)) }
        let host = UIHostingController(rootView: editor)
        window.rootViewController = host
        window.makeKeyAndVisible()
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

    func selectBetaAndBlur() async throws {
        let webView = try XCTUnwrap(context.webView)
        _ = try await webView.evaluateJavaScript("""
        const element = document.querySelector('.tiptap');
        element.focus();
        const range = document.createRange();
        range.setStart(element.querySelector('p').firstChild, 6);
        range.setEnd(element.querySelector('p').firstChild, 10);
        const selection = window.getSelection();
        selection.removeAllRanges(); selection.addRange(range);
        document.dispatchEvent(new Event('selectionchange'));
        true;
        """)
        // Give the browser's native selection-change observer its own turn.
        _ = try await webView.evaluateJavaScript("document.querySelector('.tiptap').blur(); true")
    }
}

final class RichTextEditorFormattingTests: XCTestCase {
    @MainActor
    func testStandaloneEditorGuardsReadinessAndFormatsSelectedTextAfterBlur() async throws {
        let host = HostedFormattingEditor(html: "<p>Alpha Beta</p>")
        defer { host.close() }
        XCTAssertFalse(host.context.isReady)
        host.context.toggleBold()
        host.context.presentLinkEditor()
        XCTAssertFalse(host.context.isLinkAlertPresented)
        await fulfillment(of: [host.ready], timeout: 20)
        XCTAssertTrue(host.context.isReady)
        let webView = try XCTUnwrap(host.context.webView)
        let initial = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(initial, "<p>Alpha Beta</p>")
        try await host.selectBetaAndBlur()
        host.context.toggleBold()
        let formatted = try await webView.evaluateJavaScript("window.getContent()") as? String
        XCTAssertEqual(formatted, "<p>Alpha <strong>Beta</strong></p>")
    }

    @MainActor
    func testLinkAndImageCommandsRetainSelectionAndRoundTripAttributes() async throws {
        let host = HostedFormattingEditor(html: "<p>Alpha Beta</p>")
        defer { host.close() }
        await fulfillment(of: [host.ready], timeout: 20)
        let webView = try XCTUnwrap(host.context.webView)
        try await host.selectBetaAndBlur()
        host.context.setLink(url: "https://example.com/a?q=one&other=two")
        let link = try await webView.evaluateJavaScript("""
        const link = document.querySelector('.tiptap a');
        ({text: link?.textContent, href: link?.getAttribute('href')});
        """) as? [String: String]
        XCTAssertEqual(link?["text"], "Beta")
        XCTAssertEqual(link?["href"], "https://example.com/a?q=one&other=two")
        host.context.removeLink()
        let noLink = try await webView.evaluateJavaScript("document.querySelector('.tiptap a') === null") as? Bool
        XCTAssertEqual(noLink, true)
        host.context.insertImage(url: "data:image/png;base64,iVBORw0KGgo=", alt: "Image's label")
        let alt = try await webView.evaluateJavaScript("document.querySelector('.tiptap img')?.alt") as? String
        XCTAssertEqual(alt, "Image's label")
    }

    @MainActor
    func testContextReplacementRejectsOldViewStateAndDetach() {
        let context = EditorContext()
        let oldView = WKWebView()
        let newView = WKWebView()
        context.attach(oldView)
        context.markReady(oldView)
        context.attach(newView)
        XCTAssertFalse(context.isReady)
        context.markReady(oldView)
        XCTAssertFalse(context.isReady)
        context.markReady(newView)
        context.updateState(["focused": true, "active": ["bold"]], from: newView)
        context.updateState(["focused": false, "active": []], from: oldView)
        context.detach(oldView)
        XCTAssertTrue(context.isReady)
        XCTAssertTrue(context.isFocused)
        XCTAssertEqual(context.activeFormats, ["bold"])
        context.detach(newView)
        XCTAssertFalse(context.isReady)
        XCTAssertFalse(context.isFocused)
    }

#if os(iOS)
    @MainActor
    func testIOSContainerShowsToolbarOnlyAfterReadinessAndEditorFocus() async throws {
        let host = HostedFormattingEditor(html: "<p>Layout</p>")
        defer { host.close() }
        await fulfillment(of: [host.ready], timeout: 20)
        let webView = try XCTUnwrap(host.context.webView)
        var responder: UIResponder? = webView
        while responder != nil && !(responder is EditorViewController) { responder = responder?.next }
        let controller = try XCTUnwrap(responder as? EditorViewController)
        let bar = try XCTUnwrap(controller.view.subviews.first {
            $0.accessibilityIdentifier == "RichTextEditor.FormattingToolbarHost"
        })
        host.context.updateState(["focused": false, "active": []], from: webView)
        controller.updateToolbar()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(bar.isHidden)
        host.context.updateState(["focused": true, "active": []], from: webView)
        controller.updateToolbar()
        controller.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.height, 52, accuracy: 1)
        XCTAssertLessThanOrEqual(bar.frame.maxY, controller.view.bounds.maxY + 1)
        XCTAssertLessThanOrEqual(webView.frame.maxY, bar.frame.minY + 1)
        host.context.resetReadiness()
        controller.updateToolbar()
        controller.view.layoutIfNeeded()
        XCTAssertTrue(bar.isHidden)
    }

    @MainActor
    func testDockedFloatingAndOffscreenKeyboardGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 1000)
        let safe = CGRect(x: 0, y: 20, width: 800, height: 960)
        let docked = EditorKeyboardGeometry(bounds: bounds, safeArea: safe,
            keyboard: CGRect(x: 0, y: 700, width: 800, height: 300))
        XCTAssertTrue(docked.reservesBottomSpace)
        XCTAssertEqual(docked.toolbarWidth, 800)
        let floating = EditorKeyboardGeometry(bounds: bounds, safeArea: safe,
            keyboard: CGRect(x: 650, y: 400, width: 320, height: 240))
        XCTAssertFalse(floating.reservesBottomSpace)
        XCTAssertEqual(floating.toolbarWidth, 320)
        XCTAssertLessThanOrEqual(floating.toolbarCenterX + floating.toolbarWidth / 2, safe.maxX)
        let absent = EditorKeyboardGeometry(bounds: bounds, safeArea: safe,
            keyboard: CGRect(x: 0, y: 980, width: 800, height: 0))
        XCTAssertTrue(absent.reservesBottomSpace)
        XCTAssertEqual(absent.toolbarWidth, safe.width)
    }
#endif
}
#endif
