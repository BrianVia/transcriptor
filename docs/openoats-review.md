# OpenOats Review & Feature Roadmap for Transcriptor

**Date:** 2026-04-08
**Source:** https://github.com/yazinsai/OpenOats (commit f8fe1a6)

## Overview

OpenOats is a macOS meeting note-taker that transcribes both sides of a conversation in real time and surfaces relevant talking points from a personal knowledge base. It sits in the same problem space as Transcriptor (local meeting recording + transcription) but layers a full intelligence stack on top.

This document captures our analysis of OpenOats's architecture, what it does well, and what Transcriptor should consider adopting.

---

## What OpenOats Does

- **Real-time local transcription** of mic (you) + system audio (them)
- **Knowledge base search (RAG)** — point at a folder of markdown/text files, it chunks, embeds, and searches them during calls
- **Live AI suggestions** — surfaces talking points from your KB when the conversation hits a relevant moment
- **LLM-generated meeting notes** — summary, action items, decisions after sessions
- **Multi-provider support** — Ollama (fully local), OpenRouter (cloud), OpenAI-compatible endpoints
- **Auto-detection** — calendar events, camera activation, mic activity trigger recording
- **Hidden from screen sharing** — overlay window excluded from screen capture
- **Webhook on session end** — POST transcript to external services
- **Auto-updates** via Sparkle
- **Homebrew distribution** via custom cask

---

## Architecture

### Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6.2 |
| Platform | macOS 15+ (Apple Silicon) |
| UI | SwiftUI |
| Build system | Swift Package Manager |
| Audio capture | FluidAudio (mic + system) |
| Transcription | Parakeet v2, WhisperKit, Qwen3-ASR (local); AssemblyAI, ElevenLabs Scribe (cloud) |
| Embeddings | Voyage AI, Ollama, OpenAI-compatible |
| LLM | OpenRouter, Ollama, MLX |
| Auto-updates | Sparkle |
| Secrets | macOS Keychain |
| CI | GitHub Actions (4 workflows) |

### Codebase Stats

| Metric | Value |
|--------|-------|
| Source files | 93 Swift files (~24,300 LOC) |
| Test files | 26 files (~6,000 LOC) |
| Dependencies | 4 (FluidAudio, Sparkle, WhisperKit, LaunchAtLogin) |
| Largest file | SessionRepository.swift (1,217 LOC) |

### Source Layout

```
OpenOats/Sources/OpenOats/
  App/              # Lifecycle, coordination, controllers (10 files)
  Domain/           # Pure types: MeetingState, Utterance, ExternalCommand (4 files)
  Models/           # Data models, transcript store, sidecast (6 files)
  Intelligence/     # Suggestion engine, KB search, notes, LLM clients (11 files)
  Transcription/    # Multi-backend ASR, diarization, echo filter (13 files)
  Audio/            # Mic + system audio capture, recording (4 files)
  Meeting/          # Detection, calendar, camera monitor, webhooks (6 files)
  Storage/          # Session repository, templates, import (4 files)
  Settings/         # Store, types, secure storage (3 files)
  Views/            # SwiftUI interface (13 files)
  Wizard/           # Setup wizard, provider detection (6 files)
  Utils/            # Logging (1 file)
```

### Key Architectural Patterns

**1. Pure State Machine (AppCoordinator)**
- Synchronous `transition(from:on:)` function
- States: `idle` -> `recording(metadata)` -> `ending(metadata)` -> `idle`
- Side effects dispatched after state transitions, not before
- Prevents race conditions on rapid start/stop

**2. Observable State (@Observable / @MainActor)**
- All mutable state lives in `@Observable` classes marked `@MainActor`
- Uses Swift 6.2 Observation framework (not Combine)
- Workaround for SwiftUI 6.2 bug: `@ObservationIgnored nonisolated(unsafe)` backing stores with manual `access(keyPath:)` / `withMutation(keyPath:)` tracking

**3. Service Locator / DI (AppContainer)**
- Single composition root owns all long-lived services
- Lazy initialization
- Enables test scenarios with scripted/mocked dependencies

**4. Repository Pattern (SessionRepository)**
- Abstracts JSONL session storage
- Atomic file operations
- Querying, batch operations, versioning

**5. 3-Layer Suggestion Pipeline (SuggestionEngine)**
- Layer 1: Continuous context — pre-fetches KB on partial speech every N seconds
- Layer 2: Instant retrieval + local heuristic gate on finalized utterances
- Layer 3: Streaming LLM synthesis
- Throttled via `BurstDecayThrottle` + duplicate suppression

**6. Adaptive Polling (LiveSessionController)**
- 250ms poll during recording (responsive UI)
- 2s poll when idle (minimal overhead)

---

## What OpenOats Does Well (Lessons for Transcriptor)

### 1. Real-Time AI Suggestions

The core differentiator. During a call, OpenOats searches the user's knowledge base and surfaces relevant talking points at decision moments. The 3-layer pipeline ensures low latency:
- Pre-fetch runs continuously on partial speech
- Retrieval + heuristic gate fires on finalized utterances
- LLM synthesis streams only when the gate approves

**Relevance to Transcriptor:** Transcriptor captures and transcribes but does nothing intelligent with the transcript afterward. Even a post-session summary would be a major upgrade.

### 2. Knowledge Base / RAG Integration

Users point at a folder of `.md` / `.txt` files. OpenOats:
1. Chunks by markdown headings (80-500 words, header breadcrumb prepended)
2. Embeds via Voyage AI, Ollama, or any OpenAI-compatible endpoint
3. Caches embeddings locally (only re-embeds changed files)
4. Searches with multi-query approach (latest utterance, topic, summary, open question)
5. Reranks results via Voyage AI `rerank-2.5-lite`

**Relevance to Transcriptor:** A knowledge base layer would let users surface prep docs, customer briefs, and prior meeting notes during calls.

### 3. Speaker Diarization (Mic + System)

OpenOats captures mic (you) and system audio (them) separately via `MicCapture` + `SystemAudioCapture`, then runs parallel `StreamingTranscriber` instances. This gives speaker-labeled transcripts without needing a diarization model.

Includes `AcousticEchoFilter` to handle echo between mic and system audio.

**Relevance to Transcriptor:** Transcriptor captures system audio only. Adding mic capture for speaker separation would make transcripts significantly more useful.

### 4. Structured Meeting Format (`openoats/v1`)

Standardized output with YAML frontmatter:

```markdown
---
schema: openoats/v1
title: "Meeting Title"
date: 2026-03-20T14:00:00+01:00
duration: 47
participants:
  - You
  - Them
recorder: "Your Name"
tags: [product, launch]
engine: parakeet-tdt-v2
app: zoom
---

# Meeting Title

## Summary
...

## Action Items
- [ ] Task [owner:: You] [due:: 2026-03-25]

## Decisions
- Decision point

## Transcript
[00:00:00] **You:** Utterance text.
[00:00:05] **Them:** Response.
```

Features:
- Obsidian Dataview-compatible (queryable frontmatter + inline fields)
- Grep-friendly: `rg '- \[ \]' meetings/ | rg 'owner:: You'`
- Three processing stages: raw -> cleaned -> LLM-enriched

**Relevance to Transcriptor:** Transcriptor outputs raw transcript text to `transcript.md` with no structure. A proper format with metadata and sections would make transcripts more useful and searchable.

### 5. Multi-Provider LLM Support

OpenOats supports:
- **Cloud:** OpenRouter (GPT-4o, Claude, Gemini, Mistral, Llama)
- **Local:** Ollama (any model)
- **Hybrid:** OpenAI-compatible endpoints (llama.cpp, llamaswap, LiteLLM, vLLM)

Provider selection is per-feature (LLM, embeddings, transcription can each use different providers).

**Relevance to Transcriptor:** Zero LLM integration today. Adding optional LLM support for post-meeting notes would be straightforward.

### 6. Multi-Backend Transcription

Five backends behind a `TranscriptionBackend` protocol:

| Backend | Type | Notes |
|---------|------|-------|
| Parakeet v2 | Local (FluidAudio) | Default, fast |
| WhisperKit | Local | Apple Neural Engine |
| Qwen3-ASR | Local/Ollama | Multilingual |
| AssemblyAI | Cloud | High accuracy |
| ElevenLabs Scribe | Cloud | Speaker diarization |

Each backend handles its own model lifecycle (download, prepare, transcribe).

**Relevance to Transcriptor:** Hard-wired to whisper.cpp. A backend abstraction would let you swap in better models as they appear.

### 7. Transcript Post-Processing

`BatchTextCleaner` and `LiveTranscriptCleaner` handle:
- Filler word removal ("um", "uh", "like")
- Punctuation correction
- Speaker attribution fixes
- Real-time cleaning during capture

**Relevance to Transcriptor:** Raw whisper.cpp output with no post-processing. Even basic filler removal would improve readability.

### 8. Webhook Integration

`WebhookService` fires an HMAC-signed POST on session end:

```json
{
  "sessionID": "...",
  "startedAt": "...",
  "endedAt": "...",
  "title": "...",
  "utteranceCount": 42,
  "transcript": [
    { "speaker": "You", "text": "...", "timestamp": "..." }
  ]
}
```

**Relevance to Transcriptor:** Simple to implement, enables Slack/CRM/Notion automation.

### 9. Meeting Detection

`MeetingDetector` monitors multiple signals:
- Calendar events (EventKit)
- App launches (Zoom, Teams, Meet)
- Camera activation (`CameraActivityMonitor`)
- Mic activity (`CoreAudioSignalSource`)

Auto-starts recording when signals converge.

**Relevance to Transcriptor:** The indicator has some calendar integration, but detection could be more robust with multi-signal approach.

### 10. Comprehensive Testing

26 test files covering:
- State machine transitions (all paths, double-start guards, timeouts)
- Session repository (CRUD, cleanup, versioning)
- Settings validation and keychain integration
- Knowledge base (embedding cache, rerank, relevance)
- Meeting detection (app tracking, audio activity, dismissal)
- Transcription engine (model download, streaming, finalization)
- Notes generation (LLM calls, markdown serialization)

**Relevance to Transcriptor:** No tests currently. Should add tests for at minimum: recording lifecycle, transcription, config management.

---

## Recommended Feature Roadmap for Transcriptor

### Phase 1: Foundation (Low Effort, High Impact)

| # | Feature | Description | Effort |
|---|---------|-------------|--------|
| 1 | **Structured transcript format** | YAML frontmatter (title, date, duration, model) + timestamped lines. Obsidian-compatible. | Small |
| 2 | **Transcript post-processing** | Filler removal, basic punctuation cleanup on whisper.cpp output | Small |
| 3 | **Webhook on session end** | POST transcript to configurable URL with HMAC signing | Small |
| 4 | **Searchable session metadata** | Store session metadata JSON alongside transcripts, add `search` CLI command | Small |
| 5 | **Test suite** | Tests for recording lifecycle, state management, config, transcription | Medium |

### Phase 2: Intelligence Layer (Medium Effort, High Impact)

| # | Feature | Description | Effort |
|---|---------|-------------|--------|
| 6 | **Post-meeting LLM notes** | Generate summary, action items, decisions via Ollama or OpenRouter after recording stops | Medium |
| 7 | **Speaker diarization** | Add mic capture alongside system audio for You/Them separation. Requires echo cancellation. | Medium |
| 8 | **Configurable note templates** | Let users define custom prompts for note generation (e.g., standup, 1:1, interview) | Small |
| 9 | **Multi-backend transcription** | Abstract whisper.cpp behind a `TranscriptionBackend` interface. Add WhisperKit or Parakeet as alternatives. | Medium |

### Phase 3: Advanced Features (High Effort, High Impact)

| # | Feature | Description | Effort |
|---|---------|-------------|--------|
| 10 | **Knowledge base indexing** | Chunk + embed a folder of markdown files. Local via Ollama or cloud via Voyage AI / OpenAI-compatible. | High |
| 11 | **Real-time KB search** | During recording, search KB on each transcribed chunk and surface relevant notes | High |
| 12 | **Multi-provider LLM support** | Support Ollama (local), OpenRouter (cloud), OpenAI-compatible endpoints with provider selection | Medium |
| 13 | **Real-time suggestion engine** | Full 3-layer pipeline: pre-fetch, gate, streaming synthesis | Very High |

### Phase 4: Polish

| # | Feature | Description | Effort |
|---|---------|-------------|--------|
| 14 | **Enhanced meeting detection** | Multi-signal: calendar + camera + mic + app detection | Medium |
| 15 | **Setup wizard** | Guided onboarding: check dependencies, select providers, validate API keys | Medium |
| 16 | **Batch re-transcription** | Re-process old recordings with better models or settings | Small |

---

## OpenOats Weaknesses to Avoid

1. **Large files** — SessionRepository.swift (1,217 LOC), SettingsStore.swift (1,169 LOC), TranscriptionEngine.swift (1,088 LOC). Keep files under 400 LOC.
2. **Observable state explosion** — 16+ observable properties on some classes. Group related properties into structs.
3. **SwiftUI workarounds** — The `nonisolated(unsafe)` pattern for Observable properties is a Swift 6.2 bug workaround. May not apply to Transcriptor's CLI-first architecture.
4. **macOS-only** — Transcriptor's CLI architecture is more portable. Preserve that advantage.
5. **No named participants** — OpenOats only supports You/Them. If adding diarization, consider multi-speaker from the start.
6. **Hardcoded magic numbers** — Cooldown timers, cache TTLs, similarity thresholds scattered through code. Use named constants.

---

## Key Files Worth Studying

| File | Why |
|------|-----|
| `Intelligence/SuggestionEngine.swift` | 3-layer real-time suggestion architecture |
| `Intelligence/KnowledgeBase.swift` | Embedding-based RAG with caching and reranking |
| `Intelligence/NotesEngine.swift` | LLM-powered meeting notes generation |
| `Intelligence/OpenRouterClient.swift` | Multi-provider LLM client |
| `Transcription/TranscriptionBackend.swift` | Backend abstraction protocol |
| `Transcription/TranscriptionEngine.swift` | Dual-stream transcription orchestration |
| `Audio/MicCapture.swift` + `SystemAudioCapture.swift` | Dual audio capture |
| `Transcription/AcousticEchoFilter.swift` | Echo cancellation for mic + system |
| `Intelligence/BatchTextCleaner.swift` | Filler removal, punctuation cleanup |
| `Meeting/WebhookService.swift` | Webhook implementation with HMAC signing |
| `Storage/SessionRepository.swift` | Session metadata and JSONL storage |
| `Domain/MeetingState.swift` | Pure state machine pattern |
| `App/AppCoordinator.swift` | Orchestration with side-effect isolation |
| `docs/superpowers/` | Architecture design documents and refactoring plans |
