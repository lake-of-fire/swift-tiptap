/// A fixed set of policies applied before an editor's web view is created.
public enum RichTextEditorProfile: String, Hashable, Sendable {
    /// The existing rich document editor, including images and its iOS
    /// formatting accessory. This preserves `RichTextEditorView` behavior.
    case standard

    /// A local writing surface with nonpersistent WebKit storage, a bundled
    /// resource policy, and no private input-accessory customization.
    ///
    /// Images and automatic link creation are disabled. Text, rich formatting,
    /// explicit links, and ruby remain supported; HTML is still normalized by
    /// Tiptap. Preserve any unsupported import separately before loading it.
    /// This does not persist drafts, implement a plain-text projection, or
    /// suppress the system keyboard when the editor becomes first responder.
    case localWriting

    var usesPersistentWebsiteData: Bool { self == .standard }
    var usesFormattingAccessory: Bool { self == .standard }
    var restrictsNavigationToEditorPage: Bool { self == .localWriting }
    var editorResourceName: String {
        self == .standard ? "tiptap-editor" : "tiptap-local-writing"
    }
}
