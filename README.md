# Transcriptor

Meeting recording and transcription using local Whisper. Records system audio + mic, transcribes in real-time chunks, outputs markdown transcripts.

## Features

- 🎙️ **System Audio Capture** - Uses ScreenCaptureKit to capture all system audio (meeting apps, browser, etc.)
- 📝 **Real-time Transcription** - 30-second chunks transcribed as you record
- 🔒 **Fully Local** - Whisper runs on your machine, no data leaves your computer
- 📊 **Menu Bar Indicator** - Shows recording status with duration
- 🗂️ **Organized Output** - Transcripts land in `~/transcripts/` with timestamps

<img width="448" height="252" alt="image" src="https://github.com/user-attachments/assets/cb884962-f4b3-49f9-9c08-f2964b8c711c" />


## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel Mac (M-series recommended for faster transcription)
- ~2GB disk space for Whisper model

## Installation

```bash
# Clone the repo
git clone <repo-url> transcriptor
cd transcriptor

# Run the installer
chmod +x install.sh
./install.sh
```

The installer will:
1. Install dependencies (Homebrew, Bun, ffmpeg)
2. Build the Swift audio capture binary
3. Build the menu bar indicator
4. Clone and build whisper.cpp
5. Download the `large-v3-turbo` Whisper model (~1.5GB)
6. Install the CLI

### Grant Permissions

After installation, grant Screen Recording permission:

1. Open **System Settings** → **Privacy & Security**
2. Click **Screen Recording**
3. Enable **Terminal** (or your terminal app)
4. Restart Terminal

## Usage

### CLI

```bash
# Start recording
transcriptor start "Weekly Standup"

# Stop recording
transcriptor stop

# Check status
transcriptor status

# List all transcripts
transcriptor list

# Open a transcript
transcriptor open standup

# Check installation
transcriptor doctor

# Configure
transcriptor config
transcriptor config set chunkDurationSeconds 45
```

### Raycast Extension

Install the Raycast extension for quick access:

```bash
cd raycast-extension
npm install
npm run dev
```

Commands:
- **Start Recording** - Enter meeting name and start
- **Stop Recording** - Stop current recording
- **Recording Status** - Check if recording
- **View Transcripts** - Browse and open transcripts

## Output

Transcripts are saved to `~/transcripts/` with this structure:

```
~/transcripts/
└── 2024-12-08_weekly-standup/
    ├── transcript.md      # The transcript with timestamps
    ├── audio.wav          # Merged audio (if retention enabled)
    └── chunks/            # Temporary chunk files (cleaned up)
```

### Transcript Format

```markdown
# Weekly Standup

**Date:** 12/8/2024
**Started:** 9:30:00 AM

---

**[0:00]**
Hey everyone, let's get started with the standup...

**[0:30]**
So the deploy went well yesterday, no issues...

**[1:00]**
I'm working on the new feature today...

---

**Ended:** 9:45:30 AM
```

## Configuration

Edit `~/.transcriptor/config.json` or use the CLI:

| Option | Default | Description |
|--------|---------|-------------|
| `audioRetentionDays` | 7 | Days to keep audio files |
| `transcriptRetentionDays` | 90 | Days to keep transcripts |
| `deleteAudioAfterTranscript` | false | Delete audio after transcription |
| `whisperModel` | large-v3-turbo | Whisper model to use |
| `chunkDurationSeconds` | 30 | Recording chunk duration |

### Available Models

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| `tiny` | 75MB | Fastest | Basic |
| `base` | 142MB | Fast | Good |
| `small` | 466MB | Medium | Better |
| `medium` | 1.5GB | Slow | Great |
| `large-v3-turbo` | 1.5GB | Medium | Excellent |
| `large-v3` | 3GB | Slowest | Best |

To change models:

```bash
transcriptor config set whisperModel small
# Then download the model
cd ~/.transcriptor/bin/whisper-cpp
bash ./models/download-ggml-model.sh small
mv models/ggml-small.bin ../models/
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  Raycast Extension / CLI                                        │
│  └── Start/Stop/Status/Browse                                   │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  transcriptor CLI (Bun)                                         │
│  ├── Orchestrates recording in 30s chunks                       │
│  ├── Calls whisper.cpp per chunk                                │
│  ├── Appends results to transcript.md in real-time              │
│  └── Manages state, config, retention                           │
└──────────────────────┬──────────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  transcriptor-audio (Swift)                                     │
│  └── ScreenCaptureKit for system audio capture                  │
└─────────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### "Screen Recording permission denied"
1. Open System Settings → Privacy & Security → Screen Recording
2. Make sure Terminal (or your terminal app) is checked
3. Restart Terminal

### "whisper.cpp not found"
```bash
transcriptor doctor
./install.sh  # Re-run installer
```

### Transcription is slow
- Use a smaller model: `transcriptor config set whisperModel small`
- Increase chunk duration: `transcriptor config set chunkDurationSeconds 60`
- M-series Macs are significantly faster

### Audio not capturing
- Make sure the meeting app is playing audio (not muted)
- Check that Screen Recording permission is granted
- Try running `transcriptor-audio --output test.wav` manually

## License

MIT
