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

If WebKit reloads the editor page or terminates its content process, the wrapper
restores the latest value in the native HTML binding as a new baseline. Old page
callbacks and queued loads cannot overwrite the replacement page. `onEditorReady`
runs again after recovery. Input stays disabled and context commands are ignored
until that baseline is installed. JavaScript undo history, selection, and edits not yet delivered to the
native binding cannot survive a terminated web process.

### Local-writing host and acknowledged transactions

For an app-owned writing workspace, opt into the public host:

```swift
RichTextEditorHost(
    htmlContent: stableDocumentBinding,
    documentID: documentID,
    editorContext: context,
    profile: .localWriting,
    onEditorReady: activateCurrentDocument
)
```

**This profile stays read-only until its actual document has been admitted.**
`onEditorReady` means the page and normalized HTML binding are ready; it does not
enable local-writing input. Every baseline load disables input again. The
standard `RichTextEditorView` and `.standard` host retain their existing input,
formatting and Reader behavior.

The local profile uses a fresh nonpersistent WebKit store, a restricted bundled
page, full whitespace preservation, no images/autolinks, and no execution of the
legacy formatting-accessory installer. It is not a lossless arbitrary-HTML import
path: keep unsupported source separately before parsing it into this editor.

Use the versioned JSON endpoint for coherent snapshots and acknowledged edits:

```swift
let responseData = try await context.localWritingRequest(requestData)
// Decode and validate the actual response before adopting it or enabling input.
```

The method accepts/returns bounded UTF-8 JSON `Data` (maximum 256 KiB per message).
It uses `WKWebView.callAsyncJavaScript` arguments, so document text is never
interpolated into JavaScript source. It captures the current native content
generation, checks it inside the executing page, and checks it again before
returning. Replaced/unbound contexts and replies crossing a new baseline fail,
even when the replacement HTML is identical.

The v1 activation request contains `version: 1`, `operation: "activate"`, a fresh
command `namespace` UUID, `expectedHTML` matching the normalized current binding,
and `owner`. The owner has UUID fields `contentContextID`, `documentID`, `editorID`
and `pageID`, plus nonnegative safe-integer `admissionGeneration` and
`baselineGeneration`. Optional `initialSelection` has canonical UTF-16
`lowerBound`/`upperBound`; it is applied to the real editor without focusing it.
The returned `status: "snapshot"` contains the actual HTML, canonical plain text,
selection, composition and independent document/selection/input clocks. Validate
that source and establish the domain baseline before sending
`operation: "setInputEnabled", enabled: true` with the same owner/namespace.

`context.$localWritingSnapshotJSON` publishes subsequent versioned coherent
messages. The initial event may arrive before the activation call returns; do
not treat it as an already-admitted document. Snapshot events are transient and
contain text. The application owns durable checkpoints and must not log or cache
them in unrelated stores. A transaction acknowledgment is not a disk-save receipt.

The `replace` operation includes a namespace/ordinal command ID, the complete
expected source clock, schema/projection versions, a canonical UTF-16 range, its
exact `expectedText`, and literal `replacement`. The receiver synchronously checks
those guards and settled composition, then applies one undoable PM transaction.
Identical replacements preserve selection and redo. Exact retries return the
original receipt; evicted old ordinals remain consumed. A `revoke` request
prevents a not-yet-applied ordinal from applying later, or returns its existing
outcome. Cancelling a Swift task alone does not prove cancellation of a WebKit edit.

Canonical v1 text preserves Unicode and whitespace, uses one LF per actual
text-block boundary/hard break, omits visual list markers and ruby readings,
and retains empty/trailing blocks. Editing a simple ruby base invalidates that
whole annotation in the same undo event. Unsupported nodes and unmappable
selections are refused; a selected reading is never silently treated as a base
caret. Literal CR (including CRLF) and NUL are outside v1's supported content:
HTML parsing would normalize or drop them on reopen. Replacements containing
them are refused before mutation, and snapshots containing them are unavailable
for checkpointing. Original source remains available for recovery; the bridge
does not silently normalize it. LF and tab round-trip unchanged. The exact wire
fields and bounded receipt policy live in
[`WebEditor/src/local-writing-bridge.js`](WebEditor/src/local-writing-bridge.js).

### Source-bound review annotations

The local-writing profile also accepts ephemeral inline annotations. They are
ProseMirror decorations, not document nodes or marks: installing, inspecting or
clearing them does not change text, HTML, selection, snapshot clocks or history.
The native application owns edit classification, identity and rejection policy.

Send `operation: "setAnnotations"` with the current `owner` and `namespace`, a
fresh `setID` UUID, `expectedDocumentSequence` matching the snapshot's document
clock, and an `annotations` array. Each entry contains:

- `id`: a nonempty, exact UTF-8 identity of at most 64 bytes, unique within the set.
- `range`: canonical UTF-16 `lowerBound`/`upperBound` at grapheme boundaries.
- `expectedText`: the exact current text in that range.
- `kind`: `"added"`, `"changed"` or `"removed"`. Only removed entries have an empty range.
- `label`: a nonempty localized accessibility label of at most 512 UTF-8 bytes.

Sets are limited to 256 nonoverlapping entries and the normal 256 KiB message
bound. Acknowledgments contain `status: "annotations"`, the requested `setID`
and `accepted`. Requests must be serialized by the native owner. Each validly
scoped request supersedes the previous set, including a refused stale set. An
empty array clears annotations even if its expected document sequence is old.

Text edits have dotted highlights with keyboard activation. Deletions and
whitespace-only edits have explicit boundary buttons with CSS-only symbols.
Labels are literal attributes. Decorations and their labels are omitted from
document serialization and clipboard copying. A short stationary text tap opens
the annotation after a brief delay; another press, selection gesture, context
menu or document change cancels it. Long press and drag retain normal selection
behavior. Keyboard and assistive-technology activation are immediate.

Activation arrives through `context.$localWritingSnapshotJSON` as
`status: "annotationActivated"`, `setID`, `annotationID` and a coherent settled
`snapshot`. The receiver revalidates the document sequence and exact text before
emitting it. The application must still validate the live set and edit identity
before presenting details. Selection-only changes retain annotations. Typing,
formatting, undo/redo, composition, disabled input, a replacement baseline or
retirement clears them; they never silently map through changed text or revive
from history. The standard profile does not install this annotation plugin.

Use `setInputEnabled` with `enabled: false` to preserve a read-only draft for recovery. The
`retire` operation instead disables/blurs input, clears live text and undo/redo,
drops pending payloads, and refuses the old owner. Storage deletion is still an
application responsibility. WebKit reload requires a fresh owner/namespace and
another actual-baseline admission. Native IME/focus, context replacement and
late-reply regressions require the real Apple test host; portable bundle tests
do not establish those native behaviors.

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
npm test
```

`verify` rebuilds in memory and compares every byte with the committed
`tiptap-bundle.js`. After changing the entry point or dependencies, run
`npm run build` and commit the source, lockfile, and generated bundle together.
The Swift package still loads the committed asset without a Node.js dependency
at app build or runtime.

The annotation tests execute the committed production bundle in Node/JSDOM,
including real ProseMirror clipboard and history paths. They do not establish
WKWebView gesture timing, rendered layout, VoiceOver or native IME behavior.

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
