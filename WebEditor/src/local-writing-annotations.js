import { Plugin, PluginKey } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'

const key = new PluginKey('localWritingAnnotations')
const empty = () => ({ decorations: DecorationSet.empty, setID: null, markers: [] })
const attribute = 'data-local-writing-annotation'

/** Ephemeral presentation only. The bridge validates the source document and
 * the native owner decides which edits exist and what opening one means. */
export function createLocalWritingAnnotations(getEditor, onActivate) {
  let pointer = null
  let pendingTap = null
  const cancelTap = () => {
    if (pendingTap) pendingTap.window.clearTimeout(pendingTap.timer)
    pendingTap = null
  }

  const target = (view, event) => {
    const element = event.target?.nodeType === 1 ? event.target : event.target?.parentElement
    const marker = element?.closest(`[${attribute}]`)
    return marker && view.dom.contains(marker) ? marker : null
  }
  const activate = (view, element) => {
    const current = key.getState(view.state)
    if (!current?.setID || !element || !view.dom.contains(element)) return false
    const marker = current.markers.find(value => value.id === element.getAttribute(attribute))
    if (!marker) return false
    return onActivate({ setID: current.setID, expectedDocumentSequence: current.expectedDocumentSequence, marker })
  }
  const moved = event => {
    if (!pointer) return
    if (Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) > 8) pointer.moved = true
  }
  const plugin = new Plugin({
    key,
    state: {
      init: empty,
      apply(transaction, previous) {
        // Never map a source-bound marker through typing, formatting, or history.
        // A fresh native request must validate the new document first.
        if (transaction.docChanged) { pointer = null; cancelTap(); return empty() }
        const next = transaction.getMeta(key)
        if (next) { pointer = null; cancelTap(); return next }
        if (transaction.selectionSet && !transaction.selection.empty) cancelTap()
        return previous
      }
    },
    props: {
      decorations(state) { return key.getState(state).decorations },
      handleDOMEvents: {
        pointerdown(view, event) {
          cancelTap()
          const element = target(view, event)
          const current = key.getState(view.state)
          pointer = event.button === 0 && event.isPrimary !== false && element && current.setID
            ? { id: element.getAttribute(attribute), setID: current.setID, pointerID: event.pointerId,
                x: event.clientX, y: event.clientY, started: event.timeStamp, moved: false }
            : null
          // A boundary button is a separate control. Text highlights retain
          // their ordinary native caret, drag, and long-press behavior.
          if (pointer && element.tagName === 'BUTTON') {
            event.preventDefault()
            return true
          }
          return false
        },
        pointermove(_view, event) { moved(event); return false },
        pointerup(_view, event) {
          moved(event)
          if (pointer && pointer.pointerID !== event.pointerId) pointer = null
          return false
        },
        pointercancel() { pointer = null; cancelTap(); return false },
        contextmenu() { pointer = null; cancelTap(); return false },
        dragstart() { pointer = null; cancelTap(); return false },
        dblclick() { pointer = null; cancelTap(); return false },
        click(view, event) {
          const element = target(view, event)
          const candidate = pointer
          pointer = null
          cancelTap()
          if (!element || event.button !== 0 || event.detail > 1) return false
          // detail=0 covers assistive-technology activation and native button
          // clicks. A physical tap must be short, stationary and selection-free.
          if (event.detail !== 0 && (!candidate || candidate.moved ||
              candidate.id !== element.getAttribute(attribute) ||
              candidate.setID !== key.getState(view.state).setID ||
              event.timeStamp - candidate.started > 500 || !view.state.selection.empty)) return false
          if (event.detail === 0) {
            if (!activate(view, element)) return false
          } else {
            // Let a second press or selection gesture cancel a single-tap
            // detail action. Revalidate again when the deferred tap executes.
            const window = view.dom.ownerDocument.defaultView
            const setID = key.getState(view.state).setID
            const timer = window.setTimeout(() => {
              pendingTap = null
              if (!view.isDestroyed && view.state.selection.empty && key.getState(view.state).setID === setID) activate(view, element)
            }, 250)
            pendingTap = { window, timer }
          }
          event.preventDefault()
          return true
        },
        keydown(view, event) {
          if (event.key !== 'Enter' && event.key !== ' ') return false
          cancelTap()
          const element = target(view, event)
          if (!element || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return false
          if (!activate(view, element)) return false
          event.preventDefault()
          return true
        }
      }
    },
    view() { return { destroy() { pointer = null; cancelTap() } } }
  })

  const replace = value => {
    const editor = getEditor()
    if (!editor || editor.isDestroyed || !key.getState(editor.state)) return
    editor.view.dispatch(editor.state.tr.setMeta(key, value).setMeta('addToHistory', false))
  }
  return {
    plugin,
    clear() {
      pointer = null
      cancelTap()
      const editor = getEditor()
      if (editor && key.getState(editor.state)?.setID) replace(empty())
    },
    install({ setID, expectedDocumentSequence, markers }) {
      const editor = getEditor()
      const decorations = markers.map(marker => {
        const attributes = {
          class: `local-writing-annotation local-writing-annotation-${marker.kind}`,
          [attribute]: marker.id,
          'aria-label': marker.label
        }
        // Structural newlines and whitespace-only edits can have no visible
        // inline box. Give them the same explicit boundary control as deletion.
        if (marker.from !== marker.to && marker.expectedText.trim()) {
          return Decoration.inline(marker.from, marker.to,
            { ...attributes, role: 'button', tabindex: '0' })
        }
        return Decoration.widget(marker.from, () => {
          const button = editor.view.dom.ownerDocument.createElement('button')
          for (const [name, value] of Object.entries(attributes)) button.setAttribute(name, value)
          button.type = 'button'
          button.contentEditable = 'false'
          // CSS supplies the visible symbol. There is no decoration text to
          // contaminate DOM text selection, clipboard payloads or projections.
          return button
        }, { key: `${setID}:${marker.id}`, side: 1, ignoreSelection: true,
          stopEvent: event => ['mousedown', 'touchstart', 'pointerdown'].includes(event.type) })
      })
      replace({ setID, expectedDocumentSequence, markers,
        decorations: DecorationSet.create(editor.state.doc, decorations) })
    }
  }
}
