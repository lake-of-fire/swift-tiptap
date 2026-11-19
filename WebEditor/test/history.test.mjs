import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { JSDOM, VirtualConsole } from 'jsdom'

const bundle = await readFile(new URL('../../Sources/TipTapSwift/Resources/RichTextEditor/tiptap-bundle.js', import.meta.url), 'utf8')
const plain = value => JSON.parse(JSON.stringify(value))

async function session(t, html = '<p>prefix target suffix</p>') {
  const errors = []
  const events = []
  const transactions = []
  const virtualConsole = new VirtualConsole()
  virtualConsole.on('jsdomError', error => errors.push(error.message))
  virtualConsole.on('error', (...parts) => errors.push(parts.join(' ')))
  const dom = new JSDOM('<!doctype html><html><body><div id="editor"></div></body></html>', {
    url: 'https://history-qualification.invalid', runScripts: 'outside-only',
    pretendToBeVisual: true, virtualConsole
  })
  const { window } = dom
  window.TextEncoder = TextEncoder
  window.__tipTapBridgeGeneration = 'history-test'
  window.__tipTapContentProfile = 'localWriting'
  window.webkit = {
    messageHandlers: Object.fromEntries(['contentChanged', 'editorReady', 'localWritingSnapshot'].map(name => [name, {
      postMessage: value => events.push({ name, value: plain(value) })
    }]))
  }
  window.Range.prototype.getClientRects = () => []
  window.Range.prototype.getBoundingClientRect = () => new window.DOMRect(0, 0, 0, 0)
  window.HTMLElement.prototype.scrollIntoView = () => {}
  window.scrollBy = () => {}
  window.eval(bundle)
  window.initEditor('', '')
  await new Promise(resolve => window.setTimeout(resolve, 0))
  const editor = window.document.querySelector('.tiptap').editor
  window.loadContent(html, 'generation-A')
  editor.on('transaction', ({ transaction }) => transactions.push(transaction))
  const owner = {
    contentContextID: randomUUID(), documentID: randomUUID(), editorID: randomUUID(), pageID: randomUUID(),
    admissionGeneration: 0, baselineGeneration: 0
  }
  const namespace = randomUUID()
  const send = (operation, fields = {}) => plain(window.localWritingRequest({ version: 1, operation, owner, namespace, ...fields }))
  assert.equal(send('activate', { expectedHTML: editor.getHTML() }).status, 'snapshot')
  send('setInputEnabled', { enabled: true })
  const snapshot = () => send('snapshot').snapshot
  let ordinal = 0
  const replace = (lowerBound, upperBound, replacement, fields = {}) => {
    const before = snapshot()
    // Deliberately use the opposite property order to the receiver's marker.
    const id = { ordinal: ++ordinal, namespace }
    return send('replace', {
      id, expectedClock: before.clock, range: { lowerBound, upperBound },
      expectedText: before.document.plainText.slice(lowerBound, upperBound), replacement,
      schemaVersion: 1, projectionVersion: 1, ...fields
    })
  }
  t.after(() => {
    editor.destroy()
    window.close()
    assert.deepEqual(errors, [], 'The production bundle must not cause browser errors')
  })
  return { window, editor, events, transactions, owner, namespace, send, snapshot, replace }
}

function expectCheckpoint(h, expected, checkpoint, epoch, previousSequence) {
  const snapshot = h.snapshot()
  assert.equal(snapshot.document.plainText, expected)
  assert.deepEqual(snapshot.history, { epoch, checkpoint })
  if (previousSequence !== undefined) assert.ok(snapshot.clock.document > previousSequence)
  return snapshot
}

test('each owned insertion, individual rejection and whole revert is one real undo event', async t => {
  const h = await session(t)
  const baseline = h.snapshot()
  assert.match(baseline.history.epoch, /^[0-9a-f-]{36}$/u)
  assert.equal(baseline.history.checkpoint, null)
  const insertion = h.replace(7, 13, 'Hello world')
  assert.equal(insertion.outcome, 'applied')
  const epoch = insertion.snapshot.history.epoch
  assert.equal(epoch, baseline.history.epoch)
  assert.deepEqual(insertion.snapshot.history.checkpoint, insertion.id)
  const rejection = h.replace(7, 12, 'Hi')
  assert.equal(rejection.outcome, 'applied')
  const wholeRevert = h.replace(7, 15, 'Hi folks')
  assert.equal(wholeRevert.outcome, 'applied')
  let sequence = wholeRevert.snapshot.clock.document
  for (const [text, checkpoint] of [
    ['prefix Hi world suffix', rejection.id],
    ['prefix Hello world suffix', insertion.id],
    ['prefix target suffix', null]
  ]) {
    assert.equal(h.window.undo(), true)
    sequence = expectCheckpoint(h, text, checkpoint, epoch, sequence).clock.document
  }
  assert.equal(h.window.undo(), false)
  for (const [text, checkpoint] of [
    ['prefix Hello world suffix', insertion.id],
    ['prefix Hi world suffix', rejection.id],
    ['prefix Hi folks suffix', wholeRevert.id]
  ]) {
    assert.equal(h.window.redo(), true)
    sequence = expectCheckpoint(h, text, checkpoint, epoch, sequence).clock.document
  }
  assert.equal(h.window.redo(), false)
})

test('selection, decorations and unchanged/refused commands preserve checkpoint and redo', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  assert.equal(h.window.undo(), true)
  const before = h.snapshot()
  h.editor.commands.setTextSelection({ from: 8, to: 14 })
  assert.equal(h.send('setAnnotations', {
    setID: randomUUID(), expectedDocumentSequence: before.clock.document,
    annotations: [{ id: 'change', range: { lowerBound: 7, upperBound: 13 }, expectedText: 'target',
      kind: 'changed', label: 'Inspect edit' }]
  }).accepted, true)
  const unchanged = h.replace(7, 13, 'target')
  assert.equal(unchanged.outcome, 'noChange')
  assert.deepEqual(unchanged.snapshot.history, before.history)
  const refused = h.replace(7, 13, 'oops', { expectedText: 'wrong source' })
  assert.equal(refused.outcome, 'rejected')
  assert.deepEqual(h.snapshot().history, before.history)
  assert.equal(h.snapshot().clock.document, before.clock.document)
  assert.equal(h.window.redo(), true)
  expectCheckpoint(h, 'prefix Hello suffix', insertion.id, before.history.epoch)
})

test('ordinary typing then Undo to identical bytes can never restore earlier authority', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  h.editor.commands.insertContent('!')
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
  assert.equal(h.window.undo(), true)
  assert.equal(h.snapshot().document.plainText, insertion.snapshot.document.plainText)
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
  for (const action of ['undo', 'redo', 'redo']) {
    assert.equal(h.window[action](), true)
    assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
    assert.equal(h.snapshot().history.checkpoint, null)
  }
})

test('equal-text real transactions advance the document clock and revoke provenance', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  const before = h.snapshot()
  h.editor.view.dispatch(h.editor.state.tr.insertText('Hello', 8, 13))
  const after = h.snapshot()
  assert.deepEqual(after.document, before.document)
  assert.ok(after.clock.document > before.clock.document)
  assert.notEqual(after.history.epoch, before.history.epoch)
  assert.equal(after.history.checkpoint, null)
  assert.equal(h.window.undo(), true)
  assert.equal(h.snapshot().document.plainText, insertion.snapshot.document.plainText)
  assert.notEqual(h.snapshot().history.epoch, before.history.epoch)
})

test('format-only and non-history edits revoke even when visible source text remains', async t => {
  for (const mutate of [
    h => { h.editor.commands.setTextSelection({ from: 8, to: 13 }); h.editor.commands.toggleBold() },
    h => h.editor.view.dispatch(h.editor.state.tr.insertText('Hello', 8, 13).setMeta('addToHistory', false))
  ]) {
    const h = await session(t)
    const insertion = h.replace(7, 13, 'Hello')
    mutate(h)
    const after = h.snapshot()
    assert.equal(after.document.plainText, insertion.snapshot.document.plainText)
    assert.ok(after.clock.document > insertion.snapshot.clock.document)
    assert.notEqual(after.history.epoch, insertion.snapshot.history.epoch)
    assert.equal(after.history.checkpoint, null)
    assert.equal(h.window.undo(), true)
    assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
    assert.equal(h.snapshot().history.checkpoint, null)
  }
})

test('composition start revokes immediately without text, including when annotations dispatch a clear', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  h.send('setAnnotations', {
    setID: randomUUID(), expectedDocumentSequence: insertion.snapshot.clock.document,
    annotations: [{ id: 'change', range: { lowerBound: 7, upperBound: 12 }, expectedText: 'Hello',
      kind: 'changed', label: 'Inspect edit' }]
  })
  const start = h.events.length
  h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionstart', { bubbles: true }))
  const composing = h.snapshot()
  assert.equal(composing.document.plainText, insertion.snapshot.document.plainText)
  assert.equal(composing.clock.document, insertion.snapshot.clock.document)
  assert.ok(composing.clock.input > insertion.snapshot.clock.input)
  assert.notEqual(composing.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(composing.history.checkpoint, null)
  const posted = h.events.slice(start).filter(event => event.name === 'localWritingSnapshot')
    .map(event => JSON.parse(event.value.json)).filter(value => value.status === 'snapshot')
  assert.ok(posted.length > 0)
  assert.ok(posted.every(value => value.snapshot.clock.input > insertion.snapshot.clock.input))
  h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionend', { bubbles: true }))
  await new Promise(resolve => h.window.setTimeout(resolve, 0))
  assert.equal(h.snapshot().composition.kind, 'settled')
  assert.equal(h.window.undo(), true)
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
})

test('platform historyUndo/historyRedo events carry actual checkpoint provenance', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  for (const [inputType, expected, checkpoint] of [
    ['historyUndo', 'prefix target suffix', null],
    ['historyRedo', 'prefix Hello suffix', insertion.id]
  ]) {
    const event = new h.window.InputEvent('beforeinput', { inputType, bubbles: true, cancelable: true })
    h.editor.view.dom.dispatchEvent(event)
    assert.equal(event.defaultPrevented, true)
    expectCheckpoint(h, expected, checkpoint, insertion.snapshot.history.epoch)
  }
})

test('history marker is private, nonserializable and cannot be replayed as an ordinary transaction', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  const transaction = h.transactions.find(value => value.steps.length > 0)
  const marker = transaction.steps.at(-1)
  assert.throws(() => marker.toJSON(), /cannot be serialized/u)
  assert.throws(() => marker.constructor.fromJSON(h.editor.schema, { stepType: 'localWritingCheckpoint' }), /No step type/u)
  assert.equal(Object.keys(marker).length, 0)
  assert.equal(Object.isFrozen(marker), true)
  assert.equal(Object.isFrozen(Object.getPrototypeOf(marker)), true)
  assert.throws(() => { marker.apply = () => null }, TypeError)
  assert.deepEqual(plain(h.editor.getJSON()).content[0].content.map(node => node.text), ['prefix Hello suffix'])
  const before = h.snapshot()
  h.editor.view.dispatch(h.editor.state.tr.step(marker.invert(transaction.docs.at(-1))))
  const after = h.snapshot()
  assert.equal(after.document.plainText, 'prefix target suffix')
  assert.ok(after.clock.document > before.clock.document)
  assert.notEqual(after.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(after.history.checkpoint, null)
  assert.equal(h.window.undo(), true)
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
})

test('wrong owners, arbitrary request metadata and old receipts cannot move the live history cursor', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  const before = h.snapshot()
  assert.equal(h.send('snapshot', { owner: { ...h.owner, pageID: randomUUID() }, history: { epoch: randomUUID() } }).status,
    'unavailable')
  assert.deepEqual(h.send('snapshot', { history: { epoch: randomUUID(), checkpoint: insertion.id } }).snapshot, before)
  assert.equal(h.window.undo(), true)
  const undone = h.snapshot()
  const receipt = h.send('revoke', { id: insertion.id })
  assert.deepEqual(receipt.snapshot, insertion.snapshot)
  assert.deepEqual(h.snapshot(), undone)
  assert.equal(h.window.redo(), true)
  expectCheckpoint(h, 'prefix Hello suffix', insertion.id, before.history.epoch)
})

test('a new baseline and retirement erase checkpoints and actual undo history', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  h.window.loadContent(insertion.snapshot.document.html, 'generation-B')
  const loaded = h.send('activate', { expectedHTML: h.editor.getHTML() }).snapshot
  assert.notEqual(loaded.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(loaded.history.checkpoint, null)
  assert.equal(h.window.undo(), false)
  h.send('setInputEnabled', { enabled: true })
  assert.equal(h.replace(7, 12, 'Again').outcome, 'applied')
  assert.equal(h.send('retire').status, 'retired')
  assert.equal(h.window.undo(), false)
  assert.equal(h.send('snapshot').status, 'unavailable')
})

test('same-content state replacement outside transactions cannot inherit provenance', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  const state = h.editor.state
  const document = h.editor.schema.nodeFromJSON(state.doc.toJSON())
  h.editor.view.updateState(state.constructor.create({ schema: state.schema, doc: document, plugins: state.plugins }))
  const after = h.snapshot()
  assert.deepEqual(after.document, insertion.snapshot.document)
  assert.ok(after.clock.document > insertion.snapshot.clock.document)
  assert.notEqual(after.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(after.history.checkpoint, null)
})

test('ruby invalidation and exact Unicode restoration stay in the same owned history event', async t => {
  const h = await session(t, '<p>A<ruby>日本<rt>にほん</rt></ruby>か\u3099🍣B</p>')
  const baseline = h.snapshot()
  const replacement = h.replace(1, 3, '米国')
  assert.equal(replacement.outcome, 'applied')
  assert.equal(h.editor.getHTML().includes('<ruby>'), false)
  assert.equal(h.window.undo(), true)
  const undone = expectCheckpoint(h, baseline.document.plainText, null, baseline.history.epoch)
  assert.deepEqual(undone.document, baseline.document)
  assert.equal(h.window.undo(), false)
  assert.equal(h.window.redo(), true)
  expectCheckpoint(h, 'A米国か\u3099🍣B', replacement.id, baseline.history.epoch)
})

test('an appended document edit cannot borrow an owned replacement acknowledgment', async t => {
  const h = await session(t)
  let appendOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    appendTransaction(transactions, _before, after) {
      if (!appendOnce || !transactions.some(transaction => transaction.docChanged)) return null
      appendOnce = false
      return after.tr.insertText('!', after.doc.content.size - 1)
    }
  }))
  const before = h.snapshot()
  const result = h.replace(7, 13, 'Hello')
  assert.equal(result.status, 'outcomeUnavailable')
  const after = h.snapshot()
  assert.equal(after.document.plainText, 'prefix Hello suffix!')
  assert.notEqual(after.history.epoch, before.history.epoch)
  assert.equal(after.history.checkpoint, null)
  assert.equal(h.send('revoke', { id: result.id }).status, 'outcomeUnavailable')
  assert.deepEqual(h.snapshot(), after)
})

test('extra ordinary steps inside a real Undo cannot restore an owned checkpoint on Redo', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  let mutateOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    filterTransaction(transaction) {
      if (mutateOnce && Object.keys(transaction.meta).some(key => key.startsWith('history$'))) {
        mutateOnce = false
        transaction.insertText('!', transaction.doc.content.size - 1)
      }
      return true
    }
  }))
  assert.equal(h.window.undo(), true)
  const undone = h.snapshot()
  assert.equal(undone.document.plainText, 'prefix target suffix!')
  assert.notEqual(undone.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(undone.history.checkpoint, null)
  assert.equal(h.window.redo(), true)
  const redone = h.snapshot()
  assert.equal(redone.document.plainText, 'prefix Hello suffix!')
  assert.notEqual(redone.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(redone.history.checkpoint, null)
})

test('same-count replacement of a private history step cannot borrow provenance', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  let mutateOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    filterTransaction(transaction) {
      if (mutateOnce && Object.keys(transaction.meta).some(key => key.startsWith('history$'))) {
        mutateOnce = false
        const count = transaction.steps.length
        transaction.insertText('!', transaction.doc.content.size - 1)
        transaction.steps[0] = transaction.steps.pop()
        transaction.docs.length = count
        transaction.mapping.maps.length = count
        transaction.mapping.to = count
        assert.equal(transaction.steps.length, count)
      }
      return true
    }
  }))
  assert.equal(h.window.undo(), true)
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
  assert.equal(h.window.redo(), true)
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
})

test('reordered private steps cannot produce an owned replacement acknowledgment', async t => {
  const h = await session(t, '<p>A<ruby>日本<rt>にほん</rt></ruby>B</p>')
  const before = h.snapshot()
  let mutateOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    filterTransaction(transaction) {
      if (mutateOnce && transaction.steps.length > 1) {
        mutateOnce = false
        transaction.steps.reverse()
      }
      return true
    }
  }))
  assert.equal(h.replace(1, 3, '米国').status, 'outcomeUnavailable')
  assert.equal(h.snapshot().document.plainText, 'A米国B')
  assert.notEqual(h.snapshot().history.epoch, before.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
})

test('hidden compiled document edits fail even when steps, docs and maps are trimmed consistently', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  let mutateOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    filterTransaction(transaction) {
      if (mutateOnce && Object.keys(transaction.meta).some(key => key.startsWith('history$'))) {
        mutateOnce = false
        const count = transaction.steps.length
        transaction.insertText('!', transaction.doc.content.size - 1)
        transaction.steps.length = count
        transaction.docs.length = count
        transaction.mapping.maps.length = count
        transaction.mapping.to = count
      }
      return true
    }
  }))
  assert.equal(h.window.undo(), true)
  assert.equal(h.snapshot().document.plainText, 'prefix target suffix!')
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
  assert.equal(h.window.redo(), true)
  assert.equal(h.snapshot().document.plainText, 'prefix Hello suffix!')
  assert.notEqual(h.snapshot().history.epoch, insertion.snapshot.history.epoch)
  assert.equal(h.snapshot().history.checkpoint, null)
})

test('a document mutation with all steps hidden still revokes and advances the document clock', async t => {
  const h = await session(t)
  const insertion = h.replace(7, 13, 'Hello')
  let mutateOnce = true
  const Plugin = h.editor.state.plugins[0].constructor
  h.editor.registerPlugin(new Plugin({
    filterTransaction(transaction) {
      if (mutateOnce && transaction.docChanged) {
        mutateOnce = false
        transaction.steps.length = 0
      }
      return true
    }
  }))
  h.editor.commands.insertContent('!')
  const after = h.snapshot()
  assert.equal(after.document.plainText, 'prefix Hello! suffix')
  assert.ok(after.clock.document > insertion.snapshot.clock.document)
  assert.notEqual(after.history.epoch, insertion.snapshot.history.epoch)
  assert.equal(after.history.checkpoint, null)
})

test('checkpoint markers share the bounded PM history depth without retaining a second archive', async t => {
  const h = await session(t, '<p>x</p>')
  const epoch = h.snapshot().history.epoch
  const ids = []
  for (let index = 0; index < 140; index++) {
    const result = h.replace(0, 1, index % 2 ? 'x' : 'y')
    assert.equal(result.outcome, 'applied')
    ids.push(result.id)
  }
  let undone = 0
  while (h.window.undo()) {
    undone++
    assert.deepEqual(h.snapshot().history, { epoch, checkpoint: ids[139 - undone] })
    assert.ok(undone < 140)
  }
  // PM's default depth is 100, with a 20-event trimming margin.
  assert.ok(undone >= 100 && undone < 120)
  for (let index = 0; index < undone; index++) assert.equal(h.window.redo(), true)
  expectCheckpoint(h, 'x', ids.at(-1), epoch)
})
