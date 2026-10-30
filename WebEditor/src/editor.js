import { Editor, Node } from '@tiptap/core';
import StarterKit from '@tiptap/starter-kit';
import Link from '@tiptap/extension-link';
import Placeholder from '@tiptap/extension-placeholder';
import Image from '@tiptap/extension-image';
import TextAlign from '@tiptap/extension-text-align';
import Underline from '@tiptap/extension-underline';

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
let contentGeneration = null;
let formattingSelection = null;

function publishEditorState(instance = editor) {
  if (!instance) return;
  const active = ['bold', 'italic', 'underline', 'strike', 'bulletList', 'orderedList', 'blockquote']
    .filter(name => instance.isActive(name));
  for (const level of [1, 2, 3]) {
    if (instance.isActive('heading', { level })) active.push(`heading${level}`);
  }
  for (const textAlign of ['left', 'center', 'right']) {
    if (instance.isActive({ textAlign })) active.push(textAlign);
  }
  window.webkit?.messageHandlers.editorStateChanged?.postMessage({ bridgeGeneration, contentGeneration, focused: instance.isFocused, active });
}

// ProseMirror bookmarks preserve the selected range while native buttons or
// URL dialogs have focus. Map the bookmark through edits before resolving it.
function formattingChain() {
  if (!editor) return null;
  let chain = editor.chain();
  if (formattingSelection) {
    chain = chain.command(({ tr }) => {
      try { tr.setSelection(formattingSelection.resolve(tr.doc)); }
      catch { formattingSelection = null; }
      return true;
    });
  }
  return chain.focus();
}
window.initEditor = function(content, placeholder) {
  editor = new Editor({
    element: document.querySelector('#editor'),
    extensions: [
      // TipTap 3 includes these in StarterKit; use our configured instances once.
      StarterKit.configure({ link: false, underline: false }), Ruby, RubyText, RubyParenthesis,
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
    onSelectionUpdate: ({ editor: instance }) => {
      formattingSelection = instance.state.selection.getBookmark();
      publishEditorState(instance);
    },
    onTransaction: ({ editor: instance, transaction }) => {
      if (formattingSelection) formattingSelection = formattingSelection.map(transaction.mapping);
      publishEditorState(instance);
    },
    onFocus: ({ editor: instance }) => { publishEditorState(instance); },
    onBlur: ({ editor: instance }) => {
      formattingSelection = instance.state.selection.getBookmark();
      publishEditorState(instance);
    },
    onCreate: () => { window.webkit.messageHandlers.editorReady.postMessage({ bridgeGeneration }); },
  });
};
window.setContent = function(html, generation) {
  if (!editor) return;
  if (typeof generation === 'string') contentGeneration = generation;
  editor.commands.setContent(html, { emitUpdate: true });
  formattingSelection = editor.state.selection.getBookmark();
  publishEditorState();
};
window.setPlaceholder = function(value) {
  const extension = editor?.extensionManager.extensions.find(item => item.name === 'placeholder');
  if (extension) {
    extension.options.placeholder = value;
    editor.view.dispatch(editor.state.tr);
  }
};
window.publishEditorState = publishEditorState;
window.isEditorContentGeneration = function(generation) { return generation === contentGeneration; };
window.getContent = function() { return editor ? editor.getHTML() : ''; };
window.setEditable = function(value) { if (editor) editor.setEditable(value); };
window.focus = function() { if (editor) editor.commands.focus(); };
window.isActive = function(name, attrs) { return editor ? editor.isActive(name, attrs) : false; };
window.setTheme = function(theme) { document.documentElement.setAttribute('data-theme', theme); };
window.toggleBold = function() { if (editor) formattingChain().toggleBold().run(); };
window.toggleItalic = function() { if (editor) formattingChain().toggleItalic().run(); };
window.toggleStrike = function() { if (editor) formattingChain().toggleStrike().run(); };
window.toggleUnderline = function() { if (editor) formattingChain().toggleUnderline().run(); };
window.toggleHeading = function(level) { if (editor) formattingChain().toggleHeading({ level }).run(); };
window.toggleBulletList = function() { if (editor) formattingChain().toggleBulletList().run(); };
window.toggleOrderedList = function() { if (editor) formattingChain().toggleOrderedList().run(); };
window.toggleBlockquote = function() { if (editor) formattingChain().toggleBlockquote().run(); };
window.toggleCodeBlock = function() { if (editor) formattingChain().toggleCodeBlock().run(); };
window.setHorizontalRule = function() { if (editor) formattingChain().setHorizontalRule().run(); };
window.setLink = function(href) { if (editor) (href === null ? formattingChain().unsetLink().run() : formattingChain().extendMarkRange('link').setLink({ href }).run()); };
window.setImage = function(src, alt) { if (editor) formattingChain().setImage({ src, alt: alt || '' }).run(); };
window.setTextAlign = function(align) { if (editor) formattingChain().setTextAlign(align).run(); };
window.unsetTextAlign = function() { if (editor) formattingChain().unsetTextAlign().run(); };
