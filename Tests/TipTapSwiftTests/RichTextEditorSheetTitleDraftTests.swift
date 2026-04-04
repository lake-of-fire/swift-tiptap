import Testing
@testable import TipTapSwift

@MainActor
@Test func titleDraftStoreStartsWithOriginalTitle() {
    let original = "Description"
    let store = RichTextEditorSheetTitleDraftStore(title: original)

    #expect(store.originalTitle == original)
    #expect(store.draftTitle == original)
}

@MainActor
@Test func cancelRestoresOriginalTitleAfterEdits() {
    let original = "Description"
    let store = RichTextEditorSheetTitleDraftStore(title: original)

    store.draftTitle = "Draft title"
    store.cancel()

    #expect(store.draftTitle == original)
    #expect(store.originalTitle == original)
}

@MainActor
@Test func commitReturnsLatestDraftWithoutChangingOriginalTitle() {
    let original = "Description"
    let store = RichTextEditorSheetTitleDraftStore(title: original)

    store.draftTitle = "First draft"
    store.draftTitle = "Final draft"

    let committed = store.commit()

    #expect(committed == "Final draft")
    #expect(store.originalTitle == original)
    #expect(store.draftTitle == "Final draft")
}
