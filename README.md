# swift-tiptap

A Swift Package that brings the [TipTap](https://tiptap.dev) WYSIWYG rich text editor to iOS via WKWebView. Produces the same HTML output as the TipTap web editor, so content is fully compatible between your iOS and web apps.

## Features

- **WYSIWYG Editor** — Full formatting toolbar (headings, bold, italic, lists, blockquote, links, code blocks)
- **HTML In / HTML Out** — Bidirectional `@Binding var htmlContent: String`
- **Read-Only Renderer** — `HTMLContentView` for displaying HTML content with auto-sizing
- **Dark Mode** — Automatic light/dark theme via `@Environment(\.colorScheme)`
- **Ready-to-Use Sheet** — `RichTextEditorSheet` with Cancel/Done buttons
- **Zero Runtime Dependencies** — TipTap JS is pre-built and bundled as a local asset

## Requirements

- iOS 15.0+
- macOS 13.0+
- Swift 6.0+
- Xcode 16+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lake-of-fire/swift-tiptap.git", from: "0.1.0")
]
```

Or in Xcode: **File > Add Package Dependencies** and paste the repository URL.

## Usage

### Editor (Read-Write)

```swift
import TipTapSwift

struct EditorView: View {
    @State private var html = ""

    var body: some View {
        RichTextEditorView(
            htmlContent: $html,
            placeholder: "Write something..."
        )
    }
}
```

### Persistent workspaces and undo

Pass a stable `documentID` when reusing an editor for multiple documents. Change
the ID when the selected document changes, even when the two documents contain
identical HTML or use the same `EditorContext`:

```swift
// Here documents is a [UUID: String] store. Capture the selected ID when
// constructing the view, and use that same ID for both reads and writes.
let editingID = selectedDocumentID
RichTextEditorView(
    htmlContent: Binding(
        get: { documents[editingID] ?? "" },
        set: { html in
            guard documents[editingID] != nil else { return }
            documents[editingID] = html
        }
    ),
    documentID: editingID,
    editorContext: context
)
```

The binding must stay scoped to that document: capture a stable document object
or ID in its getter and setter. Do not resolve the current selection inside those
closures. SwiftUI delivers view updates asynchronously, so `documentID` retires
the old editor generation when that update arrives. A callback delivered before
the update still uses the old binding; a document-scoped binding keeps it from
writing to the newly selected document, including when the HTML is identical.

The ID is optional for a single-document editor. Keep it stable while editing;
do not generate a new UUID each time the SwiftUI body runs. Changing the ID
through a view update retires callbacks and commands from the previous document
and clears its undo, redo, selection, and pending text formatting. The existing web view, focus,
editability, and editor configuration are retained. Undo history is local to the
currently loaded document and is not restored when returning to another document.

Assigning different HTML through the binding also loads a new baseline and clears
history. Loads normalize the HTML back into the binding without emitting a
JavaScript edit event. Binding updates echoed from the editor do not reload the
document or clear its history.

Use the command context for an **undoable programmatic edit**, such as accepting
an AI rewrite. Each replacement is one undo step, separate from surrounding
typing and other replacements. Replacements that parse to the current document
leave undo/redo history and selection unchanged:

```swift
context.replaceContent(with: rewrittenHTML)
context.undo()
context.redo()
```

### Editor Sheet

```swift
import TipTapSwift

struct MyView: View {
    @State private var description = ""
    @State private var showEditor = false

    var body: some View {
        Button("Edit Description") { showEditor = true }
            .sheet(isPresented: $showEditor) {
                RichTextEditorSheet(
                    htmlContent: $description,
                    title: "Event Description",
                    placeholder: "Describe your event..."
                )
            }
    }
}
```

### HTML Content Display (Read-Only)

```swift
import TipTapSwift

struct DetailView: View {
    let htmlDescription: String
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        ScrollView {
            HTMLContentView(
                htmlContent: htmlDescription,
                contentHeight: $contentHeight
            )
            .frame(height: contentHeight)
        }
    }
}
```

### HTML Utilities

```swift
import TipTapSwift

let html = "<p>Hello <strong>world</strong></p>"
html.containsHTML           // true
html.strippingHTMLTags()    // "Hello world"
```

## TipTap Extensions Included

The pre-built JS bundle includes:

| Extension | Features |
|-----------|----------|
| **StarterKit** | Bold, Italic, Strike, Headings (H1–H3), Bullet List, Ordered List, Blockquote, Code Block, Horizontal Rule |
| **Link** | Clickable links with URL editing |
| **Placeholder** | Configurable placeholder text |

### Rebuilding the JavaScript bundle

The editor entry point is `WebEditor/src/editor.js`. `WebEditor/package-lock.json`
locks the TipTap 3.20 dependency graph and esbuild. With Node.js 20 or newer:

```sh
cd WebEditor
npm ci --ignore-scripts
npm run verify
```

`verify` rebuilds in memory and compares every byte with the committed
`tiptap-bundle.js`. After changing the entry point or dependencies, run
`npm run build` and commit the source, lockfile, and generated bundle together.
The Swift package still loads the committed asset without a Node.js dependency
at app build or runtime.

## Architecture

```
┌──────────────────────────────────────┐
│           SwiftUI View               │
│                                      │
│  RichTextEditorView / HTMLContentView│
│         (UIViewRepresentable)        │
├──────────────────────────────────────┤
│           WKWebView                  │
│  ┌────────────────────────────────┐  │
│  │  tiptap-editor.html            │  │
│  │  ├── tiptap-bundle.js (TipTap) │  │
│  │  └── tiptap-editor.css         │  │
│  └────────────────────────────────┘  │
├──────────────────────────────────────┤
│     JS ↔ Swift Bridge                │
│                                      │
│  JS → Swift (WKScriptMessageHandler) │
│  • contentChanged(html)              │
│  • editorReady()                     │
│  • editorHeightChanged(height)       │
│                                      │
│  Swift → JS (evaluateJavaScript)     │
│  • window.setContent(html)           │
│  • window.setTheme("dark"/"light")   │
│  • window.setEditable(bool)          │
│  • window.focus()                    │
└──────────────────────────────────────┘
```

## License

MIT License. See [LICENSE](LICENSE) for details.

TipTap is licensed under the [MIT License](https://github.com/ueberdosis/tiptap/blob/main/LICENSE.md).
