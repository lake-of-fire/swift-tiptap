import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { JSDOM, VirtualConsole } from 'jsdom'

const bundle = await readFile(new URL('../../Sources/TipTapSwift/Resources/RichTextEditor/tiptap-bundle.js', import.meta.url), 'utf8')
const plain = value => JSON.parse(JSON.stringify(value))

async function session(t, html = '<p>new cat and new dog and new fox</p>') {
  const errors = []
  const transactions = []
  const virtualConsole = new VirtualConsole()
  virtualConsole.on('jsdomError', error => errors.push(error.message))
  virtualConsole.on('error', (...parts) => errors.push(parts.join(' ')))
  const dom = new JSDOM('<!doctype html><html><body><div id="editor"></div></body></html>', {
    url: 'https://batch-qualification.invalid', runScripts: 'outside-only',
    pretendToBeVisual: true, virtualConsole
  })
  const { window } = dom
  window.TextEncoder = TextEncoder
  window.__tipTapBridgeGeneration = 'batch-test'
  window.__tipTapContentProfile = 'localWriting'
  window.webkit = { messageHandlers: Object.fromEntries(
    ['contentChanged', 'editorReady', 'localWritingSnapshot'].map(name => [name, { postMessage() {} }])
  ) }
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
  const request = (replacements, fields = {}) => ({
    id: { namespace, ordinal: ++ordinal }, expectedClock: snapshot().clock,
    schemaVersion: 1, projectionVersion: 1, replacements, ...fields
  })
  const patch = (lowerBound, upperBound, replacement) => ({
    range: { lowerBound, upperBound },
    expectedText: snapshot().document.plainText.slice(lowerBound, upperBound), replacement
  })
  const many = (replacements, fields = {}) => send('replaceMany', request(replacements, fields))
  const single = part => {
    const value = request([])
    delete value.replacements
    return send('replace', { ...value, ...part })
  }
  t.after(() => {
    editor.destroy()
    window.close()
    assert.deepEqual(errors, [], 'The production bundle must not cause browser errors')
  })
  return { window, editor, transactions, owner, namespace, send, snapshot, request, patch, many, single }
}

test('nonadjacent replacements preserve intervening rich markup in one actual Undo and Redo', async t => {
  const h = await session(t, '<p>new <em>kept</em> <a href="https://example.test">link</a> new</p>')
  const before = h.snapshot()
  const end = before.document.plainText.length
  const start = h.transactions.length
  const result = h.many([h.patch(0, 3, 'old'), h.patch(end - 3, end, 'original')])
  assert.equal(result.outcome, 'applied')
  assert.equal(result.snapshot.document.plainText, 'old kept link original')
  assert.match(result.snapshot.document.html, /<em>kept<\/em>/u)
  assert.match(result.snapshot.document.html, /<a [^>]*href="https:\/\/example.test"[^>]*>link<\/a>/u)
  assert.deepEqual(result.snapshot.history, { epoch: before.history.epoch, checkpoint: result.id })
  assert.equal(h.transactions.slice(start).filter(value => value.docChanged).length, 1)
  assert.equal(h.window.undo(), true)
  assert.deepEqual(h.snapshot().document, before.document)
  assert.deepEqual(h.snapshot().history, before.history)
  assert.equal(h.window.undo(), false)
  assert.equal(h.window.redo(), true)
  assert.deepEqual(h.snapshot().document, result.snapshot.document)
  assert.deepEqual(h.snapshot().history, result.snapshot.history)
  assert.equal(h.window.redo(), false)
})

test('an earlier rejection with its own marks survives a later enclosing batch', async t => {
  const h = await session(t)
  h.editor.view.dispatch(h.editor.state.tr.setStoredMarks([h.editor.schema.marks.bold.create()]))
  const middle = h.single(h.patch(12, 15, 'old'))
  assert.equal(middle.outcome, 'applied')
  assert.match(middle.snapshot.document.html, /<strong>old<\/strong>/u)
  h.editor.view.dispatch(h.editor.state.tr.setStoredMarks([]))
  const result = h.many([h.patch(0, 3, 'old'), h.patch(24, 27, 'old')])
  assert.equal(result.outcome, 'applied')
  assert.equal(result.snapshot.document.plainText, 'old cat and old dog and old fox')
  assert.match(result.snapshot.document.html, /<strong>old<\/strong>/u)
  assert.equal(h.window.undo(), true)
  assert.deepEqual(h.snapshot().document, middle.snapshot.document)
  assert.deepEqual(h.snapshot().history, middle.snapshot.history)
})

test('one command replay and revoke recover the batch receipt without applying twice', async t => {
  const h = await session(t)
  const request = h.request([h.patch(0, 3, 'old'), h.patch(12, 15, 'old')])
  const first = h.send('replaceMany', request)
  assert.equal(first.outcome, 'applied')
  assert.deepEqual(h.send('replaceMany', request), first)
  assert.deepEqual(h.send('revoke', { id: request.id }), first)
  assert.deepEqual(h.snapshot(), first.snapshot)
  assert.equal(h.send('replaceMany', { ...request,
    replacements: [{ ...request.replacements[0], replacement: 'other' }, request.replacements[1]]
  }).reason, 'commandMismatch')
  assert.deepEqual(h.snapshot(), first.snapshot)
  assert.equal(h.window.undo(), true)
  const undone = h.snapshot()
  assert.deepEqual(h.send('replaceMany', request), first)
  assert.deepEqual(h.snapshot(), undone)
})

test('unchanged and aggregate-equivalent batches preserve selection, markup and redo exactly', async t => {
  const h = await session(t, '<p><strong>a</strong><em>a</em></p>')
  const changed = h.many([h.patch(0, 1, 'x'), h.patch(1, 2, 'y')])
  assert.equal(changed.outcome, 'applied')
  assert.equal(h.window.undo(), true)
  h.editor.commands.setTextSelection({ from: 1, to: 2 })
  const before = h.snapshot()
  for (const patches of [
    [h.patch(0, 1, 'a'), h.patch(1, 2, 'a')],
    [h.patch(0, 1, ''), h.patch(1, 2, 'aa')]
  ]) {
    const result = h.many(patches)
    assert.equal(result.outcome, 'noChange')
    assert.deepEqual(result.snapshot, before)
    assert.deepEqual(h.snapshot(), before)
  }
  assert.equal(h.window.redo(), true)
  assert.deepEqual(h.snapshot().document, changed.snapshot.document)
})

test('unchanged patches do not strip a ruby or intervening marks in a changed batch', async t => {
  const h = await session(t, '<p>x <ruby><strong>日本</strong><rt>にほん</rt></ruby> y</p>')
  const result = h.many([h.patch(0, 1, 'X'), h.patch(2, 4, '日本'), h.patch(5, 6, 'Y')])
  assert.equal(result.outcome, 'applied')
  assert.equal(result.snapshot.document.plainText, 'X 日本 Y')
  assert.match(result.snapshot.document.html, /<ruby><strong>日本<\/strong><rt>にほん<\/rt><\/ruby>/u)
})

test('two edits within one ruby unwrap it once and Undo restores the exact reading and marks', async t => {
  const h = await session(t, '<p>A<ruby><strong>日本</strong><em>語</em><rt>にほんご</rt></ruby>B</p>')
  const before = h.snapshot()
  const result = h.many([h.patch(1, 2, '米'), h.patch(3, 4, '文')])
  assert.equal(result.outcome, 'applied')
  assert.equal(result.snapshot.document.plainText, 'A米本文B')
  assert.doesNotMatch(result.snapshot.document.html, /<ruby>/u)
  assert.match(result.snapshot.document.html, /<strong>米本<\/strong>/u)
  assert.match(result.snapshot.document.html, /<em>文<\/em>/u)
  assert.equal(h.window.undo(), true)
  assert.deepEqual(h.snapshot().document, before.document)
  assert.equal(h.window.redo(), true)
  assert.deepEqual(h.snapshot().document, result.snapshot.document)
})

test('all initial ranges are validated before a bad later patch can change text or history', async t => {
  const h = await session(t)
  const before = h.snapshot()
  const first = h.patch(0, 3, 'old')
  const validLast = h.patch(12, 15, 'old')
  for (const [last, reason] of [
    [{ ...validLast, expectedText: 'bad' }, 'staleSource'],
    [{ ...validLast, range: { lowerBound: 1, upperBound: 4 } }, 'invalidRange'],
    [{ ...validLast, range: { lowerBound: 0, upperBound: 0 }, expectedText: '' }, 'invalidRange'],
    [{ ...validLast, range: { lowerBound: 15, upperBound: 14 } }, 'invalidRange'],
    [{ ...validLast, range: { lowerBound: 12, upperBound: Number.MAX_SAFE_INTEGER + 1 } }, 'invalidRange'],
    [{ ...validLast, replacement: '\ud800' }, 'invalidRange'],
    [{ ...validLast, replacement: '\u0000' }, 'unsupportedProjection'],
    [{ ...validLast, replacement: '\r' }, 'unsupportedProjection'],
    [{ ...validLast, extra: true }, 'invalidRange'],
    [null, 'invalidRange']
  ]) {
    const result = h.many([first, last])
    assert.equal(result.outcome, 'rejected')
    assert.equal(result.reason, reason)
    assert.deepEqual(h.snapshot(), before)
  }
  assert.equal(h.window.undo(), false)
})

test('empty, oversized, out-of-order and duplicate-start batches are refused before mutation', async t => {
  const h = await session(t, `<p>${'x '.repeat(129)}</p>`)
  const before = h.snapshot()
  const first = h.patch(0, 1, 'y')
  for (const patches of [null, [], Array.from({ length: 129 }, (_, index) => h.patch(index * 2, index * 2 + 1, 'y')),
    [h.patch(2, 3, 'y'), first], [h.patch(0, 0, 'a'), first]]) {
    const result = h.many(patches)
    assert.equal(result.outcome, 'rejected')
    assert.equal(result.reason, 'invalidRange')
    assert.deepEqual(h.snapshot(), before)
  }
  const result = h.many(Array.from({ length: 128 }, (_, index) => h.patch(index * 2, index * 2 + 1, 'y')))
  assert.equal(result.outcome, 'applied')
  assert.equal(result.snapshot.document.plainText, `${'y '.repeat(128)}x `)
  assert.equal(h.window.undo(), true)
  assert.deepEqual(h.snapshot().document, before.document)
})

test('original scalar and grapheme boundaries reject split emoji, combining marks and ZWJ sequences', async t => {
  const h = await session(t, '<p>x😀か\u3099👩🏽‍💻z</p>')
  const before = h.snapshot()
  for (const range of [[1, 2], [3, 4], [5, 7], [7, 9]]) {
    const result = h.many([h.patch(0, 1, 'y'), h.patch(...range, 'bad')])
    assert.equal(result.outcome, 'rejected')
    assert.equal(result.reason, 'invalidRange')
    assert.deepEqual(h.snapshot(), before)
  }
})

test('mixed insertion, deletion and replacements preserve canonical bytes across newly joined graphemes', async t => {
  for (const [html, parts, expected] of [
    ['<p>Az😀Q</p>', [[1, 2, 'B'], [2, 4, '\u0301']], 'AB\u0301Q'],
    ['<p>👩x💻!</p>', [[2, 3, '\u200d'], [5, 6, '?']], '👩\u200d💻?'],
    ['<p>か\u3099猫。尾</p>', [[0, 2, 'が'], [2, 3, ''], [4, 4, '👩🏽‍💻']], 'が。👩🏽‍💻尾'],
    ['<p>start</p><p><em>middle</em></p><p>end</p>', [[0, 5, 'first'], [13, 16, 'last']], 'first\nmiddle\nlast']
  ]) {
    await t.test(expected, async t => {
      const h = await session(t, html)
      const before = h.snapshot()
      const result = h.many(parts.map(part => h.patch(...part)))
      assert.equal(result.outcome, 'applied')
      assert.equal(result.snapshot.document.plainText, expected)
      assert.equal(new Intl.Segmenter('und', { granularity: 'grapheme' }).segment(expected)
        .containing(result.snapshot.selection.lowerBound)?.index ?? expected.length, result.snapshot.selection.lowerBound)
      assert.equal(h.window.undo(), true)
      assert.deepEqual(h.snapshot().document, before.document)
      assert.equal(h.window.redo(), true)
      assert.deepEqual(h.snapshot().document, result.snapshot.document)
    })
  }
})

test('stale source, selection, owner and IME cannot admit a partial batch', async t => {
  const h = await session(t)
  const request = h.request([h.patch(0, 3, 'old'), h.patch(12, 15, 'old')])
  h.editor.commands.setTextSelection({ from: 2, to: 2 })
  const moved = h.snapshot()
  assert.equal(h.send('replaceMany', request).reason, 'staleSource')
  assert.deepEqual(h.snapshot(), moved)
  assert.equal(h.many([h.patch(0, 3, 'old')], { owner: { ...h.owner, pageID: randomUUID() } }).status, 'unavailable')
  assert.deepEqual(h.snapshot(), moved)
  h.editor.view.dom.dispatchEvent(new h.window.CompositionEvent('compositionstart', { bubbles: true }))
  const composing = h.snapshot()
  const refused = h.many([h.patch(0, 3, 'old'), h.patch(12, 15, 'old')])
  assert.equal(refused.reason, 'compositionUnsettled')
  assert.deepEqual(h.snapshot(), composing)
})

test('wire and candidate snapshot limits refuse before dispatching any batch edit', async t => {
  const h = await session(t, `<p>${'x'.repeat(100_000)}</p>`)
  const before = h.snapshot()
  const oversized = h.many([h.patch(0, 1, 'y'.repeat(262_144))])
  assert.equal(oversized.status, 'unavailable')
  assert.deepEqual(h.snapshot(), before)
  const result = h.many([h.patch(0, 1, 'y'.repeat(40_000)), h.patch(99_999, 100_000, 'z')])
  assert.equal(result.outcome, 'rejected')
  assert.equal(result.reason, 'editorUnavailable')
  assert.deepEqual(h.snapshot(), before)
  assert.equal(h.window.undo(), false)
})

test('appended edits cannot borrow a batch acknowledgment or its replay authority', async t => {
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
  const request = h.request([h.patch(0, 3, 'old'), h.patch(12, 15, 'old')])
  const result = h.send('replaceMany', request)
  assert.equal(result.status, 'outcomeUnavailable')
  const after = h.snapshot()
  assert.equal(after.document.plainText, 'old cat and old dog and new fox!')
  assert.notEqual(after.history.epoch, before.history.epoch)
  assert.equal(after.history.checkpoint, null)
  assert.equal(h.send('revoke', { id: result.id }).status, 'outcomeUnavailable')
  assert.equal(h.send('replaceMany', request).status, 'outcomeUnavailable')
  assert.deepEqual(h.snapshot(), after)
})

test('reordering or hiding a batch history step invalidates the whole event', async t => {
  for (const mutation of ['reverse', 'hidden']) {
    await t.test(mutation, async t => {
      const h = await session(t)
      const result = h.many([h.patch(0, 3, 'old'), h.patch(12, 15, 'old')])
      assert.equal(result.outcome, 'applied')
      let mutateOnce = true
      const Plugin = h.editor.state.plugins[0].constructor
      h.editor.registerPlugin(new Plugin({
        filterTransaction(transaction) {
          if (mutateOnce && Object.keys(transaction.meta).some(key => key.startsWith('history$'))) {
            mutateOnce = false
            if (mutation === 'reverse') transaction.steps.reverse()
            else {
              const count = transaction.steps.length
              transaction.insertText('!', transaction.doc.content.size - 1)
              transaction.steps.length = count
              transaction.docs.length = count
              transaction.mapping.maps.length = count
              transaction.mapping.to = count
            }
          }
          return true
        }
      }))
      assert.equal(h.window.undo(), true)
      assert.notEqual(h.snapshot().history.epoch, result.snapshot.history.epoch)
      assert.equal(h.snapshot().history.checkpoint, null)
      assert.equal(h.window.redo(), true)
      assert.notEqual(h.snapshot().history.epoch, result.snapshot.history.epoch)
      assert.equal(h.snapshot().history.checkpoint, null)
    })
  }
})
