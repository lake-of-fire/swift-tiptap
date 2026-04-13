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
    store.syncFromEditor("<p>Hello</p>")

    #expect(store.originalHTMLContent == "<p></p>")
    #expect(store.draftHTMLContent == "<p>Hello</p>")
    #expect(store.hasEdits == true)
}
