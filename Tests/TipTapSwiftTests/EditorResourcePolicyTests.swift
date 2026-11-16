import Foundation
import Testing
@testable import TipTapSwift

struct EditorResourcePolicyTests {
    private let page = URL(fileURLWithPath: "/Bundle/Resources/RichTextEditor/tiptap-local-writing.html")

    @Test func fixedProfilesHaveDistinctCreationPolicies() {
        #expect(RichTextEditorProfile.standard.usesPersistentWebsiteData)
        #expect(RichTextEditorProfile.standard.usesFormattingAccessory)
        #expect(!RichTextEditorProfile.standard.restrictsNavigationToEditorPage)
        #expect(RichTextEditorProfile.standard.editorResourceName == "tiptap-editor")
        #expect(!RichTextEditorProfile.localWriting.usesPersistentWebsiteData)
        #expect(!RichTextEditorProfile.localWriting.usesFormattingAccessory)
        #expect(RichTextEditorProfile.localWriting.restrictsNavigationToEditorPage)
        #expect(RichTextEditorProfile.localWriting.editorResourceName == "tiptap-local-writing")
    }

    @Test func exactBundledPageAndItsFragmentAreAllowed() {
        let policy = EditorResourcePolicy(editorPageURL: page)
        #expect(policy.allowsNavigation(to: page, sourceIsMainFrame: true, targetIsMainFrame: true))
        #expect(policy.allowsNavigation(
            to: URL(string: page.absoluteString + "#selection"),
            sourceIsMainFrame: true, targetIsMainFrame: true
        ))
    }

    @Test func normalizedPathMustStillResolveToTheExactPage() {
        let policy = EditorResourcePolicy(editorPageURL: page)
        #expect(policy.allowsNavigation(
            to: URL(string: "file:///Bundle/Resources/RichTextEditor/./tiptap-local-writing.html"),
            sourceIsMainFrame: true, targetIsMainFrame: true
        ))
        #expect(!policy.allowsNavigation(
            to: URL(string: "file:///Bundle/Resources/RichTextEditor/../tiptap-local-writing.html"),
            sourceIsMainFrame: true, targetIsMainFrame: true
        ))
    }

    @Test(arguments: [
        "https://example.invalid/tiptap-local-writing.html",
        "http://example.invalid/",
        "data:text/html,forged",
        "javascript:window.location.reload()",
        "about:blank",
        "file:///Bundle/Resources/RichTextEditor/tiptap-editor.html",
        "file:///Bundle/Resources/RichTextEditor/tiptap-bundle.js",
        "file:///tmp/tiptap-local-writing.html",
        "file://localhost/Bundle/Resources/RichTextEditor/tiptap-local-writing.html",
        "file://other-host/Bundle/Resources/RichTextEditor/tiptap-local-writing.html",
        "file:///Bundle/Resources/RichTextEditor/tiptap-local-writing.html?request=remote",
        "file:///Bundle/Resources/RichTextEditor/tiptap-local-writing.html?"
    ])
    func otherLocationsAndQueriesAreDenied(_ destination: String) {
        #expect(!EditorResourcePolicy(editorPageURL: page).allowsNavigation(
            to: URL(string: destination), sourceIsMainFrame: true, targetIsMainFrame: true
        ))
    }

    @Test func unavailableDestinationAndChildOrNewWindowFramesAreDenied() {
        let policy = EditorResourcePolicy(editorPageURL: page)
        #expect(!policy.allowsNavigation(to: nil, sourceIsMainFrame: true, targetIsMainFrame: true))
        #expect(!policy.allowsNavigation(to: page, sourceIsMainFrame: false, targetIsMainFrame: true))
        #expect(!policy.allowsNavigation(to: page, sourceIsMainFrame: true, targetIsMainFrame: false))
        #expect(!policy.allowsNavigation(to: page, sourceIsMainFrame: false, targetIsMainFrame: false))
    }

    @Test func invalidExpectedPageFailsClosed() {
        let policy = EditorResourcePolicy(editorPageURL: URL(string: "https://example.invalid/")!)
        #expect(!policy.allowsNavigation(to: page, sourceIsMainFrame: true, targetIsMainFrame: true))
    }
}
