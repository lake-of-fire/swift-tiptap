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

#if os(macOS)
import AppKit
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
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
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
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
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
