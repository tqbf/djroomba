# Compaction lifecycle

Compaction shrinks a context's live token footprint by replacing many live
records with one summary. It is a **separate, explicit subsystem**:
`callModel()` never auto-summarizes (Go parity).

## Records: live vs dead

Every `Record` has a `live` flag. Live records:

- are the *only* thing a `Model` sees (`callModel()` step 2 loads live records),
- are summed for `tokenUsage()`,
- are returned by `liveRecords()`.

Dead records are retained forever (append-only history; nothing is deleted) but
excluded from the model's view and token accounting. Compaction is "deaden the
old, add a fresh live summary."

## The three calls

```swift
func summarizeLiveContext(prompt: String = SummarizerPrompt.default)
    async throws -> SummaryResult
func acceptSummary(_ result: SummaryResult) throws
func rejectSummary(_ result: SummaryResult)
```

### 1. `summarizeLiveContext` — propose (no storage mutation)

- Requires a configured `Summarizer` (a `Model`); else
  `ModelError.noSummarizerConfigured`.
- Builds a synthetic, **non-persisted** `.systemPrompt` record (id `0`) holding
  the summarizer prompt and prepends it to the live records.
- Calls `summarizer.call([promptRecord] + live)`.
- Adds the summarizer's `tokensUsed` to `metrics` (it is a model call).
- Takes the **last** emitted event as the summary text.
- Returns a `SummaryResult`:
  - `summary` — the summary text,
  - `replaced` — the live records this would deaden (timestamp ascending),
  - `originalTokenCount` — sum of `estimatedTokens` over `replaced`,
  - `summaryTokenCount` — the summarizer's reported `tokensUsed`.

No storage is touched yet — the proposal can be inspected first.

### 2. `acceptSummary` — commit (atomic)

Atomically, in **one DB transaction** (all-or-nothing):

- mark every `replaced` record dead (`live = 0`),
- insert the `summary` as a **live** `.modelResponse` record.

Implemented via the store's `replaceRecords(deadenIDs:…)`. `DatabaseQueue.write`
is itself a single GRDB transaction, so a failure rolls the whole thing back
(verified by an FK-violation rollback test in Phase 2).

### 3. `rejectSummary` — discard

A pure no-op on storage. The proposal is dropped; live records stay live.

## Token effect

After accept, `tokenUsage().liveTokens` drops by roughly
`originalTokenCount − summaryTokenCount` (the replaced records leave the live
set; the summary joins it). History is preserved: `allRecords()` still returns
the now-dead originals.

## Related deadening

`setSystemPrompt(_:)` uses the same live/dead mechanism narrowly: it deadens
all prior `.systemPrompt` records for the context before inserting the new one,
so exactly one system prompt is ever live.
