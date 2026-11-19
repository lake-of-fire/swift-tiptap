import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { JSDOM, VirtualConsole } from 'jsdom'

const bundle = await readFile(new URL('../../Sources/TipTapSwift/Resources/RichTextEditor/tiptap-bundle.js', import.meta.url), 'utf8')
const plain = value => JSON.parse(JSON.stringify(value))
const selector = '[data-local-writing-annotation]'

async function session(t, html = '<p>A日本語B</p>', profile = 'localWriting') {
  const errors = []
  const events = []
  const virtualConsole = new VirtualConsole()
  virtualConsole.on('jsdomError', error => errors.push(error.message))
  virtualConsole.on('error', (...parts) => errors.push(parts.join(' ')))
  const dom = new JSDOM('<!doctype html><html><body><div id="editor"></div></body></html>', {
    url: 'https://annotation-qualification.invalid', runScripts: 'outside-only',
    pretendToBeVisual: true, virtualConsole
  })
  const { window } = dom
  window.TextEncoder = TextEncoder
  window.__tipTapBridgeGeneration = 'annotation-test'
  window.__tipTapContentProfile = profile
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
  const owner = {
    contentContextID: randomUUID(), documentID: randomUUID(), editorID: randomUUID(), pageID: randomUUID(),
    admissionGeneration: 0, baselineGeneration: 0
  }
  const namespace = randomUUID()
  const send = (operation, fields = {}) => plain(window.localWritingRequest({ version: 1, operation, owner, namespace, ...fields }))
  if (profile === 'localWriting') {
    assert.equal(send('activate', { expectedHTML: editor.getHTML() }).status, 'snapshot')
    send('setInputEnabled', { enabled: true })
  }
  const snapshot = () => send('snapshot').snapshot
  const install = (annotations, fields = {}) => send('setAnnotations', {
    setID: randomUUID(), expectedDocumentSequence: snapshot()?.clock.document ?? 0, annotations, ...fields
  })
  t.after(() => {
    editor.destroy()
    window.close()
    assert.deepEqual(errors, [], 'The production bundle must not cause browser errors')
  })
  const activations = () => events.filter(event => event.name === 'localWritingSnapshot')
    .map(event => JSON.parse(event.value.json)).filter(value => value.status === 'annotationActivated')
  const marker = id => [...editor.view.dom.querySelectorAll(selector)]
    .find(element => element.getAttribute('data-local-writing-annotation') === id)
  return { window, editor, events, owner, namespace, send, snapshot, install, activations, marker }
}

const annotation = (id = 'change', lowerBound = 1, upperBound = 4, expectedText = '日本語', kind = 'changed') => ({
  id, range: { lowerBound, upperBound }, expectedText, kind, label: 'Inspect this edit'
})
const click = (h, element, detail = 0) => element.dispatchEvent(new h.window.MouseEvent('click', {
  bubbles: true, cancelable: true, button: 0, detail
}))
const pointerEvent = (h, element, type, { time = 10, x = 0, y = 0 } = {}) => {
  const event = new h.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y })
  Object.defineProperty(event, 'timeStamp', { value: time })
  Object.defineProperty(event, 'pointerId', { value: 1 })
  element.dispatchEvent(event)
  return event
}

test('inline and deletion annotations leave exact text, HTML, clocks, selection and history unchanged', async t => {
  const h = await session(t, '<p>🍣か\u3099日本語</p>')
  h.editor.commands.setTextSelection({ from: 3, to: 5 })
  const before = h.snapshot()
  const changes = h.events.filter(event => event.name === 'contentChanged').length
  const result = h.install([
    annotation('combining', 2, 4, 'か\u3099', 'added'),
    annotation('removed', 4, 4, '', 'removed'),
    annotation('japanese', 4, 7, '日本語')
  ])
  assert.equal(result.accepted, true)
  assert.deepEqual(h.snapshot(), before)
  assert.equal(h.editor.getHTML(), before.document.html)
  assert.equal(h.editor.view.dom.textContent, before.document.plainText)
  assert.equal(h.marker('removed').tagName, 'BUTTON')
  assert.equal(h.marker('removed').textContent, '')
  assert.equal(h.marker('removed').getAttribute('aria-label'), 'Inspect this edit')
  assert.equal(h.events.filter(event => event.name === 'contentChanged').length, changes)
  assert.equal(h.window.undo(), false)
  assert.equal(h.editor.view.dom.querySelectorAll(selector).length, 3)
})

test('actual clipboard copy omits every decoration, its label and deletion marker', async t => {
  const h = await session(t)
  assert.equal(h.install([annotation(), annotation('deleted', 4, 4, '', 'removed')]).accepted, true)
  h.editor.commands.selectAll()
  const data = {}
  const event = new h.window.Event('copy', { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'clipboardData', { value: {
    clearData() { for (const key of Object.keys(data)) delete data[key] },
    setData(type, value) { data[type] = value }
  } })
  h.editor.view.dom.dispatchEvent(event)
  assert.equal(event.defaultPrevented, true)
  assert.equal(data['text/plain'], 'A日本語B')
  assert.match(data['text/html'], />A日本語B</u)
  assert.doesNotMatch(data['text/html'], /annotation|Inspect|button/u)
})

test('selection changes retain markers and activation carries the actual selected revision', async t => {
  const h = await session(t)
  const result = h.install([annotation()])
  h.editor.commands.setTextSelection({ from: 2, to: 5 })
  const snapshot = h.snapshot()
  click(h, h.marker('change'))
  assert.deepEqual(h.activations(), [{ version: 1, status: 'annotationActivated',
    setID: result.setID, annotationID: 'change', snapshot }])
  assert.deepEqual(h.snapshot(), snapshot)
})

test('deletions at either edge and an empty paragraph remain reachable without modifying the caret', async t => {
  for (const [html, position] of [['<p>日本語</p>', 0], ['<p>日本語</p>', 3], ['<p></p>', 0]]) {
    const h = await session(t, html)
    const before = h.snapshot()
    assert.equal(h.install([annotation('removed', position, position, '', 'removed')]).accepted, true)
    const button = h.marker('removed')
    assert.equal(pointerEvent(h, button, 'pointerdown').defaultPrevented, true)
    button.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
    assert.equal(h.activations().length, 1)
    assert.deepEqual(h.snapshot(), before)
  }
})

test('short inline taps open details while drag, long press, double click and range selections keep native behavior', async t => {
  const h = await session(t)
  h.install([annotation()])
  const element = h.marker('change')
  const physicalClick = time => {
    const event = new h.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0, detail: 1 })
    Object.defineProperty(event, 'timeStamp', { value: time })
    element.dispatchEvent(event)
    return event
  }
  assert.equal(pointerEvent(h, element, 'pointerdown').defaultPrevented, false)
  assert.equal(physicalClick(20).defaultPrevented, true)
  await new Promise(resolve => h.window.setTimeout(resolve, 275))
  assert.equal(h.activations().length, 1)
  pointerEvent(h, element, 'pointerdown')
  pointerEvent(h, element, 'pointermove', { x: 20 })
  assert.equal(physicalClick(20).defaultPrevented, false)
  pointerEvent(h, element, 'pointerdown')
  assert.equal(physicalClick(600).defaultPrevented, false)
  pointerEvent(h, element, 'pointerdown')
  assert.equal(physicalClick(20).defaultPrevented, true)
  // A real double click starts with a complete single click. The next press
  // cancels its deferred detail action before native word selection happens.
  pointerEvent(h, element, 'pointerdown')
  click(h, element, 2)
  h.editor.commands.setTextSelection({ from: 2, to: 5 })
  pointerEvent(h, element, 'pointerdown')
  assert.equal(physicalClick(20).defaultPrevented, false)
  await new Promise(resolve => h.window.setTimeout(resolve, 275))
  assert.equal(h.activations().length, 1)
})

test('pending physical taps cannot open a marker after composition, editing or retirement', async t => {
  for (const invalidate of [
    h => h.editor.commands.insertContent('新'),
    h => h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionstart', { bubbles: true })),
    h => h.send('retire')
  ]) {
    const h = await session(t)
    h.install([annotation()])
    const element = h.marker('change')
    pointerEvent(h, element, 'pointerdown', { time: 0 })
    const event = new h.window.MouseEvent('click', { bubbles: true, cancelable: true, button: 0, detail: 1 })
    Object.defineProperty(event, 'timeStamp', { value: 10 })
    element.dispatchEvent(event)
    invalidate(h)
    await new Promise(resolve => h.window.setTimeout(resolve, 275))
    assert.deepEqual(h.activations(), [])
  }
})

test('keyboard activation opens an inline edit and labels are literal attributes', async t => {
  const h = await session(t)
  const source = annotation()
  source.label = '<img src=x onerror="alert(1)"> か\u3099'
  h.install([source])
  const element = h.marker('change')
  assert.equal(element.getAttribute('aria-label'), source.label)
  assert.equal(h.editor.view.dom.querySelector('img'), null)
  element.dispatchEvent(new h.window.KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }))
  assert.equal(h.activations().length, 1)
  assert.equal(h.snapshot().document.plainText, 'A日本語B')
})

test('typing, formatting, undo and redo clear markers before any stale activation', async t => {
  const h = await session(t)
  h.install([annotation()])
  const detached = h.marker('change')
  h.editor.commands.insertContent('新')
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  click(h, detached)
  assert.deepEqual(h.activations(), [])
  h.window.undo()
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  assert.equal(h.install([annotation()]).accepted, true)
  assert.equal(h.window.redo(), true)
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  h.window.undo()
  h.install([annotation()])
  h.editor.commands.setTextSelection({ from: 2, to: 5 })
  h.editor.commands.toggleBold()
  assert.equal(h.editor.view.dom.querySelector(selector), null)
})

test('installing and clearing annotations preserves an existing redo entry', async t => {
  const h = await session(t)
  h.editor.commands.insertContent('新')
  assert.equal(h.window.undo(), true)
  h.install([annotation()])
  h.install([])
  assert.equal(h.window.redo(), true)
  assert.equal(h.snapshot().document.plainText, '新A日本語B')
})

test('composition clears markers, refuses new ones, and does not revive them after settlement', async t => {
  const h = await session(t)
  h.install([annotation()])
  h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionstart', { bubbles: true }))
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  assert.equal(h.install([annotation()]).accepted, false)
  h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionend', { bubbles: true }))
  await new Promise(resolve => h.window.setTimeout(resolve, 0))
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  assert.equal(h.snapshot().composition.kind, 'settled')
  assert.equal(h.install([annotation()]).accepted, true)
})

test('input disabling through either transport removes annotations and reenabling does not restore them', async t => {
  const h = await session(t)
  for (const disable of [() => h.send('setInputEnabled', { enabled: false }), () => h.window.setEditable(false)]) {
    h.send('setInputEnabled', { enabled: true })
    assert.equal(h.install([annotation()]).accepted, true)
    disable()
    assert.equal(h.editor.view.dom.querySelector(selector), null)
    assert.equal(h.install([annotation()]).accepted, false)
    h.send('setInputEnabled', { enabled: true })
    assert.equal(h.editor.view.dom.querySelector(selector), null)
  }
})

test('baseline reload and retirement invalidate annotations even if text is identical', async t => {
  const h = await session(t)
  h.install([annotation()])
  const prior = h.marker('change')
  h.window.loadContent('<p>A日本語B</p>', 'generation-B')
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  assert.equal(h.install([annotation()]).reason, 'editorUnavailable')
  click(h, prior)
  assert.deepEqual(h.activations(), [])
  h.send('activate', { expectedHTML: h.editor.getHTML() })
  h.send('setInputEnabled', { enabled: true })
  h.install([annotation()])
  h.send('retire')
  assert.equal(h.editor.view.dom.querySelector(selector), null)
  assert.equal(h.editor.getText(), '')
  assert.equal(h.install([annotation()]).reason, 'editorUnavailable')
})

test('wrong owners cannot install or clear another editor set; scoped stale clear still succeeds', async t => {
  const h = await session(t)
  h.install([annotation()])
  const wrong = h.install([], { owner: { ...h.owner, pageID: randomUUID() } })
  assert.equal(wrong.reason, 'editorUnavailable')
  assert.ok(h.marker('change'))
  assert.equal(h.install([], { expectedDocumentSequence: 999 }).accepted, true)
  assert.equal(h.editor.view.dom.querySelector(selector), null)
})

test('stale sequence, mismatched exact Unicode and split graphemes refuse the entire set', async t => {
  const h = await session(t, '<p>🍣か\u3099日本語</p>')
  const valid = annotation('valid', 4, 7, '日本語')
  for (const [markers, fields] of [
    [[valid], { expectedDocumentSequence: 999 }],
    [[annotation('bad', 2, 4, 'が')], {}],
    [[annotation('bad', 1, 2, '\udf63')], {}],
    [[annotation('bad', 3, 4, '\u3099')], {}],
    [[valid, annotation('bad', 3, 3, '', 'removed')], {}],
    [[valid, annotation('overlap', 5, 7, '本語')], {}]
  ]) {
    assert.equal(h.install([valid]).accepted, true)
    assert.equal(h.install(markers, fields).accepted, false)
    assert.equal(h.editor.view.dom.querySelector(selector), null)
  }
})

test('bounded annotation IDs, labels, counts, kinds and ranges reject malformed sets without touching the text', async t => {
  const h = await session(t)
  const source = annotation()
  const before = h.snapshot()
  const invalid = [
    [{ ...source, id: '' }], [{ ...source, id: '語'.repeat(22) }],
    [{ ...source, label: '' }], [{ ...source, label: '語'.repeat(171) }],
    [{ ...source, expectedText: '\ud800日本' }], [{ ...source, kind: 'invented' }],
    [{ ...source, kind: 'removed' }], [annotation('bad', 1, 1, '', 'added')],
    [{ ...source, range: { lowerBound: 1, upperBound: Number.MAX_SAFE_INTEGER + 1 } }],
    [source, source], Array.from({ length: 257 }, (_, index) => annotation(String(index), 1, 1, '', 'removed'))
  ]
  for (const markers of invalid) assert.equal(h.install(markers).accepted, false)
  assert.deepEqual(h.snapshot(), before)
  assert.equal(h.window.undo(), false)
})

test('ruby bases and block boundaries use canonical positions while preserving source markup', async t => {
  const h = await session(t, '<p><ruby>日本<rt>にほん</rt></ruby></p><p>語</p>')
  const before = h.snapshot()
  assert.equal(before.document.plainText, '日本\n語')
  assert.equal(h.install([
    annotation('base', 0, 2, '日本'),
    annotation('boundary', 2, 2, '', 'removed'),
    annotation('last', 3, 4, '語', 'added')
  ]).accepted, true)
  click(h, h.marker('base'))
  click(h, h.marker('boundary'))
  click(h, h.marker('last'))
  assert.deepEqual(h.activations().map(value => value.annotationID), ['base', 'boundary', 'last'])
  assert.equal(h.editor.getHTML(), before.document.html)
  assert.equal(h.snapshot().document.plainText, before.document.plainText)
})

test('newline-only and whitespace edits have visible boundary controls without copying synthetic text', async t => {
  const h = await session(t, '<p>日本</p><p> 語</p>')
  const before = h.snapshot()
  assert.equal(before.document.plainText, '日本\n 語')
  assert.equal(h.install([
    annotation('newline', 2, 3, '\n', 'added'),
    annotation('space', 3, 4, ' ', 'changed')
  ]).accepted, true)
  for (const id of ['newline', 'space']) {
    assert.equal(h.marker(id).tagName, 'BUTTON')
    assert.equal(h.marker(id).textContent, '')
    click(h, h.marker(id))
  }
  assert.deepEqual(h.activations().map(value => value.annotationID), ['newline', 'space'])
  assert.deepEqual(h.snapshot(), before)
})

test('standard profile has no annotation bridge or plugin', async t => {
  const h = await session(t, '<p>A日本語B</p>', 'standard')
  assert.equal(h.send('setAnnotations', { setID: randomUUID(), expectedDocumentSequence: 0, annotations: [annotation()] }).reason,
    'editorUnavailable')
  assert.equal(h.editor.view.dom.querySelector(selector), null)
})
