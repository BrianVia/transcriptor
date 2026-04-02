# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Transcriptor is a macOS meeting recording and transcription tool that captures system audio using ScreenCaptureKit and transcribes it locally with whisper.cpp. It consists of three main components that communicate via shared state files.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Menu Bar App / CLI                                              │
│  └── Start/Stop/Status/Browse                                    │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  transcriptor CLI (Bun/TypeScript)      cli/src/               │
│  ├── Orchestrates recording in 30s chunks                       │
│  ├── Spawns transcriptor-audio for each chunk                   │
│  ├── Calls whisper.cpp per chunk                                │
│  └── Manages state (~/.transcriptor/state.json)                 │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  transcriptor-audio (Swift)             audio-capture/          │
│  └── ScreenCaptureKit system audio → WAV (16kHz mono)           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  transcriptor-indicator (Swift)         indicator/              │
│  ├── Menu bar app showing recording status                      │
│  ├── Calendar integration via EventKit                          │
│  ├── Microphone detection for auto-start                        │
│  └── Reads state from ~/.transcriptor/state.json                │
└─────────────────────────────────────────────────────────────────┘
```

## Key Paths

- `~/.transcriptor/` - Config, state, binaries
- `~/.transcriptor/config.json` - User configuration
- `~/.transcriptor/state.json` - Recording state (shared between CLI and indicator)
- `~/.transcriptor/stop-signal` - File-based signal to stop recording
- `~/.transcriptor/bin/` - Built binaries (transcriptor-audio, transcriptor-indicator, whisper-cpp)
- `~/transcripts/` - Output directory for recordings

## Build Commands

### Swift Components
```bash
# Audio capture binary
cd audio-capture && swift build -c release
# Output: .build/release/transcriptor-audio

# Menu bar indicator
cd indicator && swift build -c release
# Output: .build/release/transcriptor-indicator
```

### CLI (Bun/TypeScript)
```bash
cd cli
bun install
bun run src/index.ts <command>  # Run directly
bun build src/index.ts --compile --outfile transcriptor  # Compile to binary
```

### Full Installation
```bash
./install.sh  # Builds everything, downloads whisper model
```

## CLI Commands

```bash
transcriptor start "Meeting Name"  # Start recording
transcriptor stop                  # Stop recording
transcriptor status                # Check recording state
transcriptor list                  # List transcripts
transcriptor open <name>           # Open transcript
transcriptor config                # Show config
transcriptor config set <key> <value>
transcriptor doctor                # Check installation
transcriptor clean                 # Remove old files per retention policy
```

## Component Communication

The CLI and indicator communicate through:
1. `~/.transcriptor/state.json` - JSON with isRecording, meetingName, startTime, outputDir, pids
2. `~/.transcriptor/stop-signal` - Writing this file signals stop (CLI watches for it)

## Recording Flow

1. CLI writes state with `isRecording: true`
2. CLI spawns `transcriptor-audio` for each 30s chunk
3. After each chunk, CLI runs whisper.cpp and appends to transcript.md
4. Indicator polls state.json to update menu bar
5. Stop: write stop-signal file, CLI catches it, transcribes final chunk, merges audio

## Configuration Options

Key config fields in `~/.transcriptor/config.json`:
- `chunkDurationSeconds` (30) - Recording chunk duration
- `whisperModel` ("large-v3-turbo") - Whisper model name
- `calendarEnabled` - Auto-detect meetings from calendar
- `autoStartRecording` - Start recording automatically when meetings begin
- `microphoneDetectionEnabled` - Detect when mic becomes active
- `microphoneAutoStart` - Auto-start recording on mic activity

## Swift Notes

- Requires macOS 13+ (uses ScreenCaptureKit)
- Audio capture uses SCStream with audio-only configuration
- Outputs 16kHz mono WAV (whisper.cpp requirement)
- Indicator uses CoreAudio for microphone monitoring
- Calendar uses EventKit for meeting detection
