import SwiftUI

/// Hosts the existing editor with creation-time storage, resource, and content
/// policies. Use `.localWriting` for an app-owned writing/review surface.
///
/// The profile is part of the web view's identity. Changing it replaces the
/// page and clears undo/redo; checkpoint edits before deliberately switching.
/// Updates within one profile preserve the existing document and page guards.
@MainActor
public struct RichTextEditorHost: View {
    @Binding private var htmlContent: String
    private let documentID: AnyHashable?
    private let placeholder: String?
    private let editorContext: EditorContext?
    private let profile: RichTextEditorProfile
    private let onEditorReady: (() -> Void)?

    /// The HTML binding must capture a stable document or document ID. Assigning
    /// a new value establishes a baseline and clears undo/redo. Native formatting
    /// commands remain available through `EditorContext` in both profiles.
    public init(
        htmlContent: Binding<String>,
        documentID: AnyHashable? = nil,
        placeholder: String? = nil,
        editorContext: EditorContext? = nil,
        profile: RichTextEditorProfile = .standard,
        onEditorReady: (() -> Void)? = nil
    ) {
        self._htmlContent = htmlContent
        self.documentID = documentID
        self.placeholder = placeholder
        self.editorContext = editorContext
        self.profile = profile
        self.onEditorReady = onEditorReady
    }

    public var body: some View {
        RichTextEditorView(
            htmlContent: $htmlContent,
            documentID: documentID,
            placeholder: placeholder,
            editorContext: editorContext,
            profile: profile,
            onEditorReady: onEditorReady
        )
        .id(profile)
    }
}
