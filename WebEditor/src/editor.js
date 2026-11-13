import { Editor, Node, createDocument } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import Placeholder from '@tiptap/extension-placeholder';
import Image from '@tiptap/extension-image';
import TextAlign from '@tiptap/extension-text-align';
import Underline from '@tiptap/extension-underline';
import { EditorState } from '@tiptap/pm/state'
import { closeHistory } from '@tiptap/pm/history'

// Keep ruby markup editable and serializable, including its reading and fallback text.
const Ruby = Node.create({
  name: 'ruby', inline: true, group: 'inline', content: 'inline*',
  parseHTML() { return [{ tag: 'ruby' }]; },
  renderHTML() { return ['ruby', 0]; },
});
const RubyText = Node.create({
  name: 'rt', inline: true, group: 'inline', content: 'inline*',
  parseHTML() { return [{ tag: 'rt' }]; },
  renderHTML() { return ['rt', 0]; },
});
const RubyParenthesis = Node.create({
  name: 'rp', inline: true, group: 'inline', content: 'inline*',
  parseHTML() { return [{ tag: 'rp' }]; },
  renderHTML() { return ['rp', 0]; },
});

let editor = null;
const bridgeGeneration = window.__tipTapBridgeGeneration;
// A WKWebView can host multiple page lifetimes. Queued native work must name
// the page it came from before it is allowed to mutate a replacement page.
const pageGeneration = Array.from(crypto.getRandomValues(new Uint32Array(4)), value => value.toString(16)).join('-')
let contentGeneration = null;
window.initEditor = function(content, placeholder) {
  editor = new Editor({
    element: document.querySelector('#editor'),
    // Native initialization installs the authoritative binding before enabling
    // input, so typing cannot be discarded while the first baseline is loading.
    editable: false,
    extensions: [
      StarterKit, Ruby, RubyText, RubyParenthesis,
      Link.configure({
        openOnClick: false,
        autolink: true,
        linkOnPaste: true,
        defaultProtocol: 'https',
        protocols: [{ scheme: 'mailto', optionalSlashes: true }, { scheme: 'tel', optionalSlashes: true }],
        HTMLAttributes: { target: '_blank', rel: 'noopener noreferrer' },
      }),
      Placeholder.configure({ placeholder: placeholder || 'Start typing...' }),
      Image.configure({ inline: false, allowBase64: true }),
      TextAlign.configure({ types: ['heading', 'paragraph'] }),
      Underline,
    ],
    content: content || '',
    onUpdate: ({ editor }) => {
      const html = editor.getHTML();
      window.webkit.messageHandlers.contentChanged.postMessage({ bridgeGeneration, contentGeneration, html });
    },
    onCreate: () => { window.requestEditorReady() },
  });
};
window.requestEditorReady = function() {
  if (!editor) return
  window.webkit.messageHandlers.editorReady.postMessage({ bridgeGeneration, pageGeneration })
}
window.isEditorPageGeneration = function(generation) { return !!editor && generation === pageGeneration }
window.loadContent = function(html, generation) {
  if (!editor) return
  contentGeneration = generation
  // Loading establishes a baseline, not an edit. Let TipTap normalize the
  // document, then reset plugin state as well as selection and stored marks.
  // Merely setting addToHistory:false leaves undo/redo from the previous doc.
  editor.commands.setContent(html, { emitUpdate: false })
  editor.view.updateState(EditorState.create({
    schema: editor.state.schema,
    doc: editor.state.doc,
    plugins: editor.state.plugins,
  }))
}
window.setContent = function(html) {
  if (!editor) return
  const document = createDocument(html, editor.schema, {}, {
    errorOnInvalidContent: editor.options.enableContentCheck,
  })
  // An equivalent replacement must not consume an undo step or discard redo.
  // Compare parsed documents so equivalent markup (such as b/strong) is a no-op.
  if (document.eq(editor.state.doc)) return
  // Programmatic edits (for example, accepting a rewrite) are one undo step,
  // independent of the typing or replacements immediately before and after.
  editor.view.dispatch(closeHistory(editor.state.tr))
  editor.commands.setContent(document, { emitUpdate: true })
  editor.view.dispatch(closeHistory(editor.state.tr))
}
window.undo = function() { return editor ? editor.commands.undo() : false }
window.redo = function() { return editor ? editor.commands.redo() : false }
window.isEditorContentGeneration = function(generation) { return generation === contentGeneration; };
window.getContent = function() { return editor ? editor.getHTML() : ''; };
window.setEditable = function(value) { if (editor) editor.setEditable(value, false) }
window.focus = function() { if (editor) editor.commands.focus(); };
window.isActive = function(name, attrs) { return editor ? editor.isActive(name, attrs) : false; };
window.setTheme = function(theme) { document.documentElement.setAttribute('data-theme', theme); };
window.toggleBold = function() { if (editor) editor.chain().focus().toggleBold().run(); };
window.toggleItalic = function() { if (editor) editor.chain().focus().toggleItalic().run(); };
window.toggleStrike = function() { if (editor) editor.chain().focus().toggleStrike().run(); };
window.toggleUnderline = function() { if (editor) editor.chain().focus().toggleUnderline().run(); };
window.toggleHeading = function(level) { if (editor) editor.chain().focus().toggleHeading({ level }).run(); };
window.toggleBulletList = function() { if (editor) editor.chain().focus().toggleBulletList().run(); };
window.toggleOrderedList = function() { if (editor) editor.chain().focus().toggleOrderedList().run(); };
window.toggleBlockquote = function() { if (editor) editor.chain().focus().toggleBlockquote().run(); };
window.toggleCodeBlock = function() { if (editor) editor.chain().focus().toggleCodeBlock().run(); };
window.setHorizontalRule = function() { if (editor) editor.chain().focus().setHorizontalRule().run(); };
window.setLink = function(href) { if (editor) (href === null ? editor.chain().focus().unsetLink().run() : editor.chain().focus().extendMarkRange('link').setLink({ href }).run()); };
window.setImage = function(src, alt) { if (editor) editor.chain().focus().setImage({ src, alt: alt || '' }).run(); };
window.setTextAlign = function(align) { if (editor) editor.chain().focus().setTextAlign(align).run(); };
window.unsetTextAlign = function() { if (editor) editor.chain().focus().unsetTextAlign().run(); };
