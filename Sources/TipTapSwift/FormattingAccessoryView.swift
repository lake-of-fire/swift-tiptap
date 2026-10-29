import SwiftUI

/// Shared controls; the editor owns their platform-specific placement.
@MainActor
struct FormattingToolbar: View {
    @ObservedObject var context: EditorContext

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 4) {
                    icon("bold", "Bold", format: "bold") { context.toggleBold() }
                    icon("italic", "Italic", format: "italic") { context.toggleItalic() }
                    icon("underline", "Underline", format: "underline") { context.toggleUnderline() }
                    heading(1)
                    heading(2)
                    heading(3)
                    icon("list.bullet", "Bullet list", format: "bulletList") { context.toggleBulletList() }
                    icon("list.number", "Numbered list", format: "orderedList") { context.toggleOrderedList() }
                    icon("link", "Add link") { context.presentLinkEditor() }
                    icon("photo", "Insert image") { context.presentImageEditor() }
                    icon("text.alignleft", "Align left", format: "left") { context.setTextAlign("left") }
                    icon("text.aligncenter", "Align center", format: "center") { context.setTextAlign("center") }
                    icon("text.alignright", "Align right", format: "right") { context.setTextAlign("right") }
                    icon("text.quote", "Block quote", format: "blockquote") { context.toggleBlockquote() }
                    icon("minus", "Horizontal rule") { context.setHorizontalRule() }
                    icon("strikethrough", "Strikethrough", format: "strike") { context.toggleStrike() }
                }
                .padding(.horizontal, 6)
            }
#if canImport(UIKit)
            Divider().frame(height: 24).padding(.horizontal, 6)
            icon("keyboard.chevron.compact.down", "Dismiss keyboard") { context.dismissKeyboard() }
                .padding(.trailing, 6)
#endif
        }
        .frame(height: 44)
        .disabled(!context.isReady)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RichTextEditor.FormattingToolbar")
    }

    private func icon(_ symbol: String, _ title: String, format: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundColor(format.map { context.activeFormats.contains($0) } == true ? .accentColor : .primary)
        .accessibilityLabel(title)
        .accessibilityIdentifier("RichTextEditor.\(title)")
        .help(title)
    }

    private func heading(_ level: Int) -> some View {
        Button { context.toggleHeading(level: level) } label: {
            Text("H\(level)")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundColor(context.activeFormats.contains("heading\(level)") ? .accentColor : .primary)
        .accessibilityLabel("Heading \(level)")
        .accessibilityIdentifier("RichTextEditor.Heading\(level)")
        .help("Heading \(level)")
    }
}
