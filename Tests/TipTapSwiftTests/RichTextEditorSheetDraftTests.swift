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
@Test func firstEditorSyncBecomesBaselineWithoutCountingAsAnEdit() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "")

    store.syncFromEditor("<p></p>")

    #expect(store.originalHTMLContent == "<p></p>")
    #expect(store.draftHTMLContent == "<p></p>")
    #expect(store.hasEdits == false)
}

@MainActor
@Test func subsequentEditorSyncsStillCountAsEdits() {
    let store = RichTextEditorSheetDraftStore(htmlContent: "")

    store.syncFromEditor("<p></p>")
    store.beginTrackingEdits()
    store.syncFromEditor("<p>Hello</p>")

    #expect(store.originalHTMLContent == "<p></p>")
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
        let store = RichTextEditorSheetDraftStore(htmlContent: "Original")
        let context = EditorContext()
        let editor = RichTextEditorView(
            htmlContent: Binding(
                get: { store.draftHTMLContent },
                set: { html in
                    store.syncFromEditor(html)
                    if html == "<p>Quick edit</p>" { edited.fulfill() }
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
        webView.evaluateJavaScript("window.webkit.messageHandlers.contentChanged.postMessage('<p>Quick edit</p>'); true") { _, error in
            XCTAssertNil(error)
        }
        await fulfillment(of: [edited], timeout: 2)
        XCTAssertTrue(store.hasEdits)
        XCTAssertEqual(store.commit(), "<p>Quick edit</p>")
    }
}
#endif
