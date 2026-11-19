import { isHistoryTransaction } from '@tiptap/pm/history'
import { Step } from '@tiptap/pm/transform'

// Provenance belongs to in-memory PM Steps, never document text or serializable
// metadata supplied by a caller. History keeps/inverts these steps with its own
// undo event. No additional document archive or unbounded command map is kept.
const ownedSteps = new WeakMap()
class OwnedStep extends Step {
  constructor(delegate, inverse, transition, index, inverted = false) {
    super()
    ownedSteps.set(this, { delegate, inverse, transition, index, inverted })
    Object.freeze(this)
  }

  apply(document) { return ownedSteps.get(this).delegate.apply(document) }
  getMap() { return ownedSteps.get(this).delegate.getMap() }
  invert() {
    // Seal both directions against the admitted source once. A caller cannot
    // supply a different document to manufacture a new owned inverse.
    const { delegate, inverse, transition, index, inverted } = ownedSteps.get(this)
    return new OwnedStep(inverse, delegate, transition, index, !inverted)
  }
  map(mapping) {
    // Changed geometry crosses the source boundary. Preserve PM's ordinary
    // editing behavior while dropping authority, even for an identity map.
    return ownedSteps.get(this).delegate.map(mapping)
  }
  toJSON() { throw new RangeError('Local-writing history checkpoints cannot be serialized') }
}
Object.freeze(OwnedStep.prototype)

function mapRanges(map) {
  const ranges = []
  map.forEach((...range) => ranges.push(...range))
  return ranges
}

function eventTransition(transaction) {
  const { steps, docs, mapping } = transaction
  const first = ownedSteps.get(steps[0])
  if (!first || steps.length !== first.transition.count || docs.length !== steps.length ||
      mapping.maps.length !== steps.length || mapping.from !== 0 || mapping.to !== steps.length) return null
  const { transition, inverted } = first
  if (!steps.every((step, index) => {
    const owned = ownedSteps.get(step)
    return owned?.transition === transition && owned.inverted === inverted &&
      owned.index === (inverted ? steps.length - index - 1 : index)
  })) return null
  // filterTransaction can mutate the compiled document and then hide its
  // added Steps. Re-execute the sealed delegates transiently, checking the
  // complete event rather than trusting tr.doc or its metadata. No document
  // from this check is retained in history provenance.
  let document = transaction.before
  try {
    for (let index = 0; index < steps.length; index++) {
      const { delegate } = ownedSteps.get(steps[index])
      if (!document.eq(docs[index])) return null
      const expectedMap = mapRanges(delegate.getMap())
      const actualMap = mapRanges(mapping.maps[index])
      if (expectedMap.length !== actualMap.length || expectedMap.some((value, i) => value !== actualMap[i])) return null
      const result = delegate.apply(document)
      if (result.failed || !result.doc) return null
      document = result.doc
    }
    if (!document.eq(transaction.doc)) return null
  } catch { return null }
  return { epoch: transition.epoch, from: inverted ? transition.to : transition.from,
    to: inverted ? transition.from : transition.to }
}

const sameCheckpoint = (left, right) => left === right || (!!left && !!right &&
  left.namespace === right.namespace && left.ordinal === right.ordinal)

/** Generic receiver provenance. The native owner decides which acknowledged
 * commands have reversible product state and whether their source still fits. */
export function createLocalWritingHistory(document, newID) {
  let epoch = { id: newID() }
  let checkpoint = null
  let observedDocument = document
  let documentChanged = false
  let issuedTransaction = null

  const invalidate = () => {
    epoch = { id: newID() }
    checkpoint = null
    issuedTransaction = null
  }

  return {
    get snapshot() {
      return { epoch: epoch.id, checkpoint: checkpoint && { ...checkpoint } }
    },
    get documentChanged() { return documentChanged },
    captured() { documentChanged = false },
    invalidate,

    prepare(transaction, id) {
      const next = Object.freeze({ namespace: id.namespace, ordinal: id.ordinal })
      const transition = { epoch, from: checkpoint, to: next, count: transaction.steps.length }
      // The existing candidate transaction already passed exact-source checks.
      // Replace each Step with an effect-identical private delegate; its docs,
      // maps, selection and metadata remain unchanged. Every Step in a replay
      // must belong to this one ordered event, so extra ordinary edits cannot
      // borrow a genuine history transaction's checkpoint.
      for (let index = 0; index < transaction.steps.length; index++) {
        const delegate = transaction.steps[index]
        transaction.steps[index] = new OwnedStep(delegate, delegate.invert(transaction.docs[index]), transition, index)
      }
      issuedTransaction = transaction
      return transaction
    },
    finish() { issuedTransaction = null },

    observe(transaction, appendedTransactions, document) {
      const transactions = [transaction, ...(appendedTransactions ?? [])].filter(Boolean)
      if (!transactions.length && document !== observedDocument) {
        documentChanged = true
        invalidate()
      }
      let priorDocument = observedDocument
      for (const current of transactions) {
        if (current.before !== priorDocument) {
          documentChanged = true
          invalidate()
        }
        priorDocument = current.doc
        if (!current.docChanged) {
          // docChanged is derived from steps.length. A filtered transaction
          // can hide all its Steps while retaining a mutated compiled doc.
          if (current.docs.length || current.mapping.maps.length || current.doc !== current.before) {
            documentChanged = true
            invalidate()
          }
          continue
        }
        // A same-text or addToHistory:false transaction still ends ownership.
        // Document revisions describe actual edits, not equality of snapshots.
        documentChanged = true
        const transition = eventTransition(current)
        if (!transition || transition.epoch !== epoch ||
            !sameCheckpoint(transition.from, checkpoint) ||
            (current !== issuedTransaction && !isHistoryTransaction(current))) {
          invalidate()
        } else {
          checkpoint = transition.to
        }
        issuedTransaction = null
      }
      if (transactions.length && priorDocument !== document) {
        documentChanged = true
        invalidate()
      }
      observedDocument = document
    },

    observeDocument(document) {
      if (document === observedDocument) return
      // A direct state replacement bypassing onTransaction cannot inherit a
      // checkpoint merely because it happens to recreate the same text.
      observedDocument = document
      documentChanged = true
      invalidate()
    }
  }
}
