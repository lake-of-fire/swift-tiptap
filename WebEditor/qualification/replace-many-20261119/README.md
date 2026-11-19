# Atomic source-bound replacements

`replaceMany` applies up to 128 independently validated source ranges as one
editor command. It preserves rich content between them and gives the full set
one receipt, one history checkpoint and one Undo/Redo event. Swift owns edit
selection and semantic policy; this receiver only enforces the admitted operation.

The actual rebuilt production bundle passed **57 tests**: the 37 existing
annotation/history cases and 20 new batch cases. The locked-source bundle
comparison also passed. [Receipt](result.json) · [Complete test log](test.log)

The batch tests cover nonadjacent edits with untouched marks and links, a prior
rejection's marks, multiple changes inside one ruby, unchanged ruby preservation,
an invalid later patch without partial mutation, strict order/overlap/count
limits, exact Unicode with combining marks and ZWJ sequences, source/selection/
IME refusal, bounded response size, repeated receipt lookup, aggregate no-change
with retained redo, one actual Undo/Redo event, and appended or altered history
transactions that must lose checkpoint authority.

This is portable Node/JSDOM execution of real Tiptap/ProseMirror. It does not
establish Apple SDK compilation, native WKWebView/IME behavior, rendered layout
or accessibility. No Apple CI was dispatched.
