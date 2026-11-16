import { Fragment } from '@tiptap/pm/model'
import { EditorState, TextSelection } from '@tiptap/pm/state'
import { closeHistory } from '@tiptap/pm/history'
import { getHTMLFromFragment } from '@tiptap/core'

const VERSION = 1
const MAX_BYTES = 262144
// Replies also carry IDs, status and independent result clocks.
const MAX_SNAPSHOT_BYTES = MAX_BYTES - 1024
const MAX_RECEIPT_BYTES = 1048576
const MAX_RECEIPTS = 16
const encoder = new TextEncoder()
const segmenter = typeof Intl.Segmenter === 'function'
  ? new Intl.Segmenter('und', { granularity: 'grapheme' }) : null
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const counter = value => Number.isSafeInteger(value) && value >= 0
const uuid = value => typeof value === 'string' && uuidPattern.test(value)
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const bytes = value => encoder.encode(JSON.stringify(value)).length
const copy = value => JSON.parse(JSON.stringify(value))
const ownKeys = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
const ownerKeys = ['contentContextID', 'documentID', 'editorID', 'pageID', 'admissionGeneration', 'baselineGeneration']
const validOwner = value => ownKeys(value, ownerKeys) && ownerKeys.slice(0, 4).every(key => uuid(value[key])) &&
  counter(value.admissionGeneration) && counter(value.baselineGeneration)
const sameOwner = (a, b) => validOwner(a) && validOwner(b) && ownerKeys.every(key => a[key] === b[key])
const validClock = value => ownKeys(value, ['document', 'selection', 'input']) &&
  counter(value.document) && counter(value.selection) && counter(value.input)
const sameClock = (a, b) => validClock(a) && validClock(b) && ['document', 'selection', 'input'].every(key => a[key] === b[key])
const validID = value => ownKeys(value, ['namespace', 'ordinal']) && uuid(value.namespace) && counter(value.ordinal) && value.ordinal > 0

function newUUID() {
  const values = crypto.getRandomValues(new Uint8Array(16))
  values[6] = (values[6] & 15) | 64
  values[8] = (values[8] & 63) | 128
  const hex = Array.from(values, value => value.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/** Base text only. Block boundaries and hard breaks are one LF; visual list
 * markers are never part of an editable range. Every boundary is mapped to
 * actual PM positions, including empty/trailing blocks. Unsupported nodes fail
 * closed instead of being silently omitted. */
export function projectDocument(doc) {
  let text = ''
  // Literal text maps linearly. Only node/structural boundaries need points;
  // a long paragraph must not allocate a Map and Set entry per UTF-16 unit.
  const segments = []
  const positions = new Map()
  const inversePoints = new Map()
  const rubies = []
  const blocks = []
  const addPosition = (offset, position) => {
    const previous = positions.get(offset)
    positions.set(offset, previous === undefined ? position : Math.min(previous, position))
    if (inversePoints.has(position) && inversePoints.get(position) !== offset) throw new Error('unsupportedProjection')
    inversePoints.set(position, offset)
  }
  const append = (value, from, to) => {
    const start = text.length
    if (value.length === to - from) {
      segments.push({ start, end: start + value.length, from, to })
    }
    addPosition(start, from)
    addPosition(start + value.length, to)
    text += value
  }
  const inline = (node, position, inRuby = false) => {
    if (node.isText) { append(node.text, position, position + node.nodeSize); return }
    if (node.type.name === 'hardBreak') { append('\n', position, position + node.nodeSize); return }
    if (node.type.name !== 'ruby' || inRuby) throw new Error('unsupportedProjection')
    const start = text.length
    addPosition(start, position)
    const base = []
    node.forEach((child, offset) => {
      if (child.type.name === 'rt' || child.type.name === 'rp') return
      base.push(child)
      inline(child, position + 1 + offset, true)
    })
    if (text.length === start) throw new Error('unsupportedProjection')
    addPosition(text.length, position + node.nodeSize)
    rubies.push({ start, end: text.length, from: position, to: position + node.nodeSize, base })
  }
  const visit = (node, position) => {
    if (['paragraph', 'heading', 'codeBlock'].includes(node.type.name)) {
      blocks.push({ node, position })
      return
    }
    if (!['doc', 'blockquote', 'bulletList', 'orderedList', 'listItem'].includes(node.type.name)) {
      throw new Error('unsupportedProjection')
    }
    node.forEach((child, offset) => visit(child, position + (node.type.name === 'doc' ? 0 : 1) + offset))
  }
  visit(doc, 0)
  if (!blocks.length) throw new Error('unsupportedProjection')
  blocks.forEach(({ node, position }, index) => {
    const start = position + 1
    if (index) {
      const previous = blocks[index - 1]
      append('\n', previous.position + previous.node.nodeSize - 1, start)
    }
    addPosition(text.length, start)
    node.forEach((child, offset) => inline(child, start + offset))
    addPosition(text.length, position + node.nodeSize - 1)
  })
  const preceding = (offset, key) => {
    let low = 0
    let high = segments.length
    while (low < high) {
      const middle = Math.floor((low + high) / 2)
      if (segments[middle][key] <= offset) low = middle + 1
      else high = middle
    }
    return segments[low - 1]
  }
  const inverse = { get(position) {
    if (inversePoints.has(position)) return inversePoints.get(position)
    const segment = preceding(position, 'from')
    return segment && position <= segment.to ? segment.start + position - segment.from : undefined
  } }
  const boundary = offset => {
    const ruby = rubies.find(value => value.start === offset || value.end === offset)
    if (ruby) return ruby.start === offset ? ruby.from : ruby.to
    const point = positions.get(offset)
    const segment = preceding(offset, 'start')
    const linear = segment && offset <= segment.end ? segment.from + offset - segment.start : undefined
    if (point === undefined && linear === undefined) throw new Error('invalidRange')
    return point === undefined ? linear : linear === undefined ? point : Math.min(point, linear)
  }
  return { text, inverse, rubies, boundary }
}

function validString(value) {
  if (typeof value !== 'string') return false
  // JSON can contain lone surrogates. Never let JS repair them into replacement
  // characters on the trip back to Swift.
  for (let i = 0; i < value.length; i++) {
    const unit = value.charCodeAt(i)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++i)
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false
    } else if (unit >= 0xdc00 && unit <= 0xdfff) return false
  }
  return true
}

// HTML tokenization normalizes literal CR/CRLF and drops NUL on reload. The
// v1 snapshot format must never acknowledge text it cannot reopen exactly.
// Preserve unsupported source outside this editor; do not silently normalize it.
const reloadableText = value => !value.includes('\r') && !value.includes('\u0000')

function graphemeBoundary(text, offset) {
  if (!counter(offset) || offset > text.length || !segmenter) return false
  if (offset === text.length) return true
  return segmenter.segment(text).containing(offset)?.index === offset
}

function followingGraphemeBoundary(text, offset) {
  if (!counter(offset) || offset > text.length || !segmenter) throw new Error('invalidRange')
  if (offset === text.length) return offset
  const part = segmenter.segment(text).containing(offset)
  if (!part) throw new Error('invalidRange')
  return part.index === offset ? offset : part.index + part.segment.length
}

/** This is editor integration only. Swift owns draft policy, durability,
 * processing and host delivery. One receiver is scoped to one actual page. */
export function createLocalWritingBridge(getEditor, postSnapshot) {
  let state = null
  let composition = { kind: 'settled', id: null }
  let compositionGeneration = 0
  let lastNotification = null
  let projectedDocument = null
  let projectionCache = null
  const projectionFor = doc => {
    if (doc !== projectedDocument) {
      const projection = projectDocument(doc)
      projectedDocument = doc
      projectionCache = projection
    }
    return projectionCache
  }
  const clearProjection = () => {
    projectedDocument = null
    projectionCache = null
  }

  const envelope = (status, fields = {}) => ({ version: VERSION, status, ...fields })
  const fail = reason => envelope('unavailable', { reason })
  const advance = value => {
    if (value >= Number.MAX_SAFE_INTEGER) throw new Error('sequenceExhausted')
    return value + 1
  }
  const capture = () => {
    const editor = getEditor()
    if (!editor || !state || state.retired) throw new Error('editorUnavailable')
    const projection = projectionFor(editor.state.doc)
    const from = projection.inverse.get(editor.state.selection.from)
    const to = projection.inverse.get(editor.state.selection.to)
    if (from === undefined || to === undefined) throw new Error('unsupportedProjection')
    // A range containing only omitted ruby reading/fallback nodes is not a
    // caret in the base text. Never silently retarget it to a base insertion.
    if (from === to && editor.state.selection.from !== editor.state.selection.to) throw new Error('unsupportedProjection')
    const selection = { lowerBound: from, upperBound: to }
    if (composition.kind === 'settled' && (!graphemeBoundary(projection.text, from) || !graphemeBoundary(projection.text, to))) {
      throw new Error('invalidRange')
    }
    const document = { html: editor.getHTML(), plainText: projection.text, schemaVersion: 1, projectionVersion: 1 }
    if (!validString(document.html) || !validString(document.plainText)) throw new Error('invalidText')
    if (!reloadableText(document.html) || !reloadableText(document.plainText)) throw new Error('unsupportedProjection')
    const previous = state.snapshot
    const clock = previous ? { ...previous.clock } : { document: 0, selection: 0, input: 0 }
    if (previous) {
      if (state.missedCapture || document.html !== previous.document.html || document.plainText !== previous.document.plainText) clock.document = advance(clock.document)
      if (state.missedCapture || !equal(selection, previous.selection)) clock.selection = advance(clock.selection)
      if (state.missedCapture || !equal(composition, previous.composition)) clock.input = advance(clock.input)
    }
    const snapshot = { owner: state.owner, clock, document, selection, composition: copy(composition) }
    if (bytes(snapshot) > MAX_SNAPSHOT_BYTES) throw new Error('payloadTooLarge')
    state.snapshot = snapshot
    state.missedCapture = false
    return copy(snapshot)
  }
  const notify = () => {
    if (!state || state.retired) return
    let message
    let identity
    try {
      const snapshot = capture()
      message = envelope('snapshot', { snapshot })
      identity = `snapshot:${snapshot.clock.document}:${snapshot.clock.selection}:${snapshot.clock.input}`
    } catch (error) {
      state.missedCapture = true
      message = fail(error.message)
      identity = `unavailable:${error.message}`
    }
    if (identity === lastNotification) return
    lastNotification = identity
    postSnapshot(message)
  }
  const remember = (ordinal, requestJSON, response) => {
    const entry = { requestJSON, response: copy(response), size: bytes(response) + encoder.encode(requestJSON).length }
    state.receipts.set(ordinal, entry)
    state.receiptBytes += entry.size
    while (state.receipts.size > MAX_RECEIPTS || state.receiptBytes > MAX_RECEIPT_BYTES) {
      const key = state.receipts.keys().next().value
      state.receiptBytes -= state.receipts.get(key).size
      state.receipts.delete(key)
    }
    return copy(response)
  }
  const receipt = (id, outcome, snapshot = null, reason = null) => envelope('result', {
    id: copy(id), outcome, reason, snapshot, resultingClock: snapshot?.clock ?? null
  })
  const reject = (request, reason, requestJSON) => remember(request.id.ordinal, requestJSON,
    receipt(request.id, 'rejected', null, reason))

  const request = value => {
    if (!value || typeof value !== 'object' || value.version !== VERSION || bytes(value) > MAX_BYTES) return fail('invalidRequest')
    const editor = getEditor()
    if (!editor) return fail('editorUnavailable')
    if (value.operation === 'activate') {
      if (!validOwner(value.owner) || !uuid(value.namespace) || !validString(value.expectedHTML)) return fail('invalidRequest')
      if (state) {
        if (!state.retired && sameOwner(value.owner, state.owner) && value.namespace === state.namespace && value.expectedHTML === state.baselineHTML) {
          try { return envelope('snapshot', { snapshot: capture() }) } catch (error) { return fail(error.message) }
        }
        return fail('editorUnavailable')
      }
      if (value.expectedHTML !== editor.getHTML() || editor.view.composing || composition.kind !== 'settled') return fail('staleSource')
      editor.setEditable(false, false)
      if (value.initialSelection != null) {
        try {
          const projection = projectDocument(editor.state.doc)
          const range = value.initialSelection
          if (!ownKeys(range, ['lowerBound', 'upperBound']) || range.upperBound < range.lowerBound ||
              !graphemeBoundary(projection.text, range.lowerBound) || !graphemeBoundary(projection.text, range.upperBound)) return fail('invalidRange')
          editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc,
            projection.boundary(range.lowerBound), projection.boundary(range.upperBound))))
        } catch { return fail('invalidRange') }
      }
      state = { owner: copy(value.owner), namespace: value.namespace, baselineHTML: value.expectedHTML,
        snapshot: null, highest: 0, receipts: new Map(), receiptBytes: 0, retired: false }
      try { const snapshot = capture(); notify(); return envelope('snapshot', { snapshot }) }
      catch (error) { state = null; return fail(error.message) }
    }
    if (!state || state.retired || !sameOwner(value.owner, state.owner) || value.namespace !== state.namespace) return fail('editorUnavailable')
    if (value.operation === 'snapshot') {
      try { return envelope('snapshot', { snapshot: capture() }) } catch (error) { return fail(error.message) }
    }
    if (value.operation === 'setInputEnabled') {
      if (typeof value.enabled !== 'boolean') return fail('invalidRequest')
      editor.setEditable(value.enabled, false)
      return envelope('inputEnabled', { enabled: value.enabled })
    }
    if (value.operation === 'retire') {
      state.retired = true
      state.snapshot = null
      state.baselineHTML = null
      state.receipts.clear()
      state.receiptBytes = 0
      clearProjection()
      compositionGeneration++
      composition = { kind: 'settled', id: null }
      editor.setEditable(false, false)
      editor.commands.blur()
      const empty = editor.schema.nodes.doc.createAndFill()
      editor.view.updateState(EditorState.create({ schema: editor.schema, doc: empty, plugins: editor.state.plugins }))
      postSnapshot(fail('editorUnavailable'))
      return envelope('retired')
    }
    if (!['replace', 'revoke'].includes(value.operation) || !validID(value.id) || value.id.namespace !== state.namespace) return fail('invalidRequest')
    const requestJSON = JSON.stringify(value)
    const previous = state.receipts.get(value.id.ordinal)
    if (previous) {
      if (value.operation === 'revoke' || previous.response.reason === 'editorUnavailable' || previous.requestJSON === requestJSON) return copy(previous.response)
      return fail('commandMismatch')
    }
    // Compact high-water survives receipt eviction. Neither retries nor lower
    // out-of-order ordinals can become fresh edits after their outcome is lost.
    if (value.id.ordinal <= state.highest) return envelope('outcomeUnavailable', { id: copy(value.id) })
    state.highest = value.id.ordinal
    if (value.operation === 'revoke') return reject(value, 'editorUnavailable', requestJSON)
    if (!validClock(value.expectedClock) || !ownKeys(value.range, ['lowerBound', 'upperBound']) ||
        !counter(value.range.lowerBound) || !counter(value.range.upperBound) || value.range.upperBound < value.range.lowerBound ||
        !validString(value.expectedText) || !validString(value.replacement)) return reject(value, 'invalidRange', requestJSON)
    if (value.schemaVersion !== 1 || value.projectionVersion !== 1) return reject(value, 'unsupportedProjection', requestJSON)
    if (!reloadableText(value.replacement)) return reject(value, 'unsupportedProjection', requestJSON)
    let before
    try { before = capture() } catch { return reject(value, 'unsupportedProjection', requestJSON) }
    if (composition.kind !== 'settled' || editor.view.composing) return reject(value, 'compositionUnsettled', requestJSON)
    if (!sameClock(value.expectedClock, before.clock)) return reject(value, 'staleSource', requestJSON)
    const { lowerBound: lower, upperBound: upper } = value.range
    const plain = before.document.plainText
    if (!graphemeBoundary(plain, lower) || !graphemeBoundary(plain, upper)) return reject(value, 'invalidRange', requestJSON)
    if (plain.slice(lower, upper) !== value.expectedText) return reject(value, 'staleSource', requestJSON)
    if (value.expectedText === value.replacement) return remember(value.id.ordinal, requestJSON, receipt(value.id, 'noChange', before))
    try {
      let projection = projectionFor(editor.state.doc)
      let transaction = closeHistory(editor.state.tr)
      // A base edit invalidates its entire simple ruby annotation. Unwrap base
      // children first, preserving marks, in the same transaction and undo event.
      const touched = projection.rubies.filter(ruby => lower === upper
        ? lower > ruby.start && lower < ruby.end : lower < ruby.end && upper > ruby.start)
      for (const ruby of touched.sort((a, b) => b.from - a.from)) {
        transaction = transaction.replaceWith(ruby.from, ruby.to, Fragment.fromArray(ruby.base))
      }
      projection = projectionFor(transaction.doc)
      transaction = transaction.insertText(value.replacement, projection.boundary(lower), projection.boundary(upper))
      const expected = plain.slice(0, lower) + value.replacement + plain.slice(upper)
      const candidateProjection = projectionFor(transaction.doc)
      if (candidateProjection.text !== expected) return reject(value, 'invalidRange', requestJSON)
      // Inserting a combining mark or ZWJ can join neighboring graphemes. Keep
      // the actual resulting caret on the next settled boundary, never expose
      // a snapshot that Swift must reject after the mutation already happened.
      const desired = lower + value.replacement.length
      const caret = followingGraphemeBoundary(expected, desired)
      transaction = transaction.setSelection(TextSelection.create(transaction.doc, candidateProjection.boundary(caret)))
      // Reserve room for the new document and independently advancing clocks
      // before dispatch, so a known limit cannot turn a mutation into a refusal.
      const candidateHTML = getHTMLFromFragment(transaction.doc.content, editor.schema)
      if (candidateProjection.inverse.get(transaction.selection.from) === undefined ||
          candidateProjection.inverse.get(transaction.selection.to) === undefined ||
          before.clock.document >= Number.MAX_SAFE_INTEGER || before.clock.selection >= Number.MAX_SAFE_INTEGER ||
          bytes({ ...before, document: { ...before.document, html: candidateHTML, plainText: expected } }) > MAX_SNAPSHOT_BYTES - 128) {
        return reject(value, 'editorUnavailable', requestJSON)
      }
      editor.view.dispatch(transaction)
      editor.view.dispatch(closeHistory(editor.state.tr))
      const after = capture()
      return remember(value.id.ordinal, requestJSON, receipt(value.id, 'applied', after))
    } catch {
      // After dispatch, never manufacture a rejection. If projection capture
      // unexpectedly fails, the issued ordinal remains consumed for reconciliation.
      return envelope('outcomeUnavailable', { id: copy(value.id) })
    }
  }

  return {
    request,
    transaction: notify,
    reset() {
      state = null
      lastNotification = null
      clearProjection()
      compositionGeneration++
      composition = { kind: 'settled', id: null }
    },
    attach(editor) {
      editor.view.dom.addEventListener('compositionstart', () => {
        compositionGeneration++
        composition = { kind: 'composing', id: newUUID() }
        notify()
      }, true)
      editor.view.dom.addEventListener('compositionend', () => {
        const generation = ++compositionGeneration
        composition = { kind: 'awaitingSettlement', id: composition.id ?? newUUID() }
        notify()
        queueMicrotask(() => {
          if (generation !== compositionGeneration || !state || state.retired || editor.view.composing) return
          // Pinned prosemirror-view adapter: explicitly flush its DOM observer,
          // then issue a real settled transaction. No timeout asserts settlement.
          if (typeof editor.view.domObserver?.flush !== 'function') return
          editor.view.domObserver.flush()
          if (generation !== compositionGeneration || editor.view.composing) return
          composition = { kind: 'settled', id: null }
          editor.view.dispatch(editor.state.tr.setMeta('localWritingCompositionBarrier', generation))
        })
      }, true)
    }
  }
}
