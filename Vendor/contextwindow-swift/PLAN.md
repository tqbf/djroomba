# PLAN.md — ContextWindow Swift port (documentation index)

This repo is a Swift port of the Go `contextwindow` library. **Future agents:
read this file and `PROGRESS.md`, then the relevant `plans/` doc.**

## What this is

A named-context + append-only record store with live/dead compaction, token
accounting, a model call loop, summarization, tools, and OpenAI provider
adapters. The SQLite schema is the durable, valuable artifact and is kept
shape-stable on purpose.

> Note: no Go source exists in this repo/machine. The plan docs are the spec of
> record. See deviations in [plans/swift-port-plan.md](plans/swift-port-plan.md).

## Documentation map

| Doc | Purpose |
|---|---|
| [PROGRESS.md](PROGRESS.md) | Current state, what's done, what's next, decisions log |
| [plans/swift-port-plan.md](plans/swift-port-plan.md) | **Master plan** — full 3-phase spec, core types, semantics, deviations, execution protocol |
| [plans/phase-1-domain-sqlite.md](plans/phase-1-domain-sqlite.md) | Phase 1 checklist + acceptance tests: domain model + GRDB SQLite spine |
| [plans/phase-2-model-loop.md](plans/phase-2-model-loop.md) | Phase 2 checklist + acceptance tests: model boundary, call loop, summarization, tools |
| [plans/phase-3-providers-harness.md](plans/phase-3-providers-harness.md) | Phase 3 checklist + acceptance tests: OpenAI adapters, CLI, compat harness, docs |
| [plans/phase-4-packaging.md](plans/phase-4-packaging.md) | Phase 4 checklist + acceptance: package for SPM reuse (locked decisions, credential safety) |
| [README.md](README.md) | Quick start, package layout, cost discipline, doc index |
| [docs/porting-notes.md](docs/porting-notes.md) | No-Go-source reality + all Phase 3 deviations |
| [docs/provider-adapter-contract.md](docs/provider-adapter-contract.md) | How to write a `Model` provider adapter |
| [docs/tool-definition-format.md](docs/tool-definition-format.md) | Neutral `JSONSchemaToolDefinition`/`JSONValue` tool format |
| [docs/compaction-lifecycle.md](docs/compaction-lifecycle.md) | summarize / accept / reject + live-vs-dead semantics |

## Phase status (summary — details in PROGRESS.md)

1. **Phase 1** — Domain model + SQLite spine — ✅ done
2. **Phase 2** — Model abstraction, call loop, summarization, tools — ✅ done
3. **Phase 3** — Provider adapters, package polish, compatibility harness — ✅ done
4. **Phase 4** — Package for SPM reuse (MIT, tools 6.0, local tag 0.1.0) — ✅ done

Phases execute serially; each in its own subagent. Phase N+1 starts only after
Phase N builds and tests green.

## Build / test

```sh
swift build
swift test                       # all logic tests, zero network
CONTEXTWINDOW_LIVE_OPENAI=1 swift test --filter Live   # 1–2 real OpenAI calls
```
