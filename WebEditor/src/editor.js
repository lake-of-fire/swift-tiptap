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
window.initEditor = function(content, placeholder) {
  editor = new Editor({
    element: document.querySelector('#editor'),
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
      window.webkit.messageHandlers.contentChanged.postMessage(html);
    },
    onCreate: () => { window.webkit.messageHandlers.editorReady.postMessage(true); },
  });
};
window.setContent = function(html) { if (editor) editor.commands.setContent(html, false); };
window.getContent = function() { return editor ? editor.getHTML() : ''; };
window.setEditable = function(value) { if (editor) editor.setEditable(value); };
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
