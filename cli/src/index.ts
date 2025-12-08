#!/usr/bin/env bun

import { startRecording, stopRecording, getStatus } from "./recorder";
import { checkWhisperInstalled } from "./transcriber";
import { loadConfig, saveConfig, paths, ensureDirectories, type Config } from "./config";
import { existsSync, readdirSync, statSync, unlinkSync, rmSync, readFileSync } from "fs";
import { join } from "path";

const VERSION = "1.0.0";

function printHelp(): void {
  console.log(`
transcriptor v${VERSION} - Meeting recording and transcription

USAGE:
  transcriptor <command> [options]

COMMANDS:
  start <name>     Start recording a meeting with the given name
  stop             Stop the current recording
  status           Check if recording is in progress
  list             List all transcripts
  open <name>      Open a transcript in your default editor
  config           Show current configuration
  config set <key> <value>  Update configuration
  doctor           Check installation status
  clean            Remove old files per retention policy
  help             Show this help message

EXAMPLES:
  transcriptor start "Weekly Standup"
  transcriptor stop
  transcriptor list
  transcriptor open 2024-12-08_weekly-standup

CONFIGURATION:
  audioRetentionDays        Days to keep audio files (default: 7)
  transcriptRetentionDays   Days to keep transcripts (default: 90)
  deleteAudioAfterTranscript  Delete audio after transcription (default: false)
  whisperModel              Whisper model to use (default: large-v3-turbo)
  chunkDurationSeconds      Recording chunk duration (default: 30)
`);
}

async function handleStart(args: string[]): Promise<void> {
  if (args.length === 0) {
    console.error("Error: Meeting name required");
    console.error("Usage: transcriptor start <name>");
    process.exit(1);
  }

  const meetingName = args.join(" ");
  await startRecording(meetingName);
  
  // Keep process running
  await new Promise(() => {});
}

async function handleStop(): Promise<void> {
  await stopRecording();
}

function handleStatus(): void {
  const status = getStatus();
  
  if (status.recording) {
    console.log(`🎙️  Recording: ${status.meetingName}`);
    console.log(`⏱️  Duration: ${status.duration}`);
  } else {
    console.log("Not recording");
  }
}

function handleList(): void {
  if (!existsSync(paths.transcripts)) {
    console.log("No transcripts found");
    return;
  }

  const entries = readdirSync(paths.transcripts)
    .filter(name => {
      const fullPath = join(paths.transcripts, name);
      return statSync(fullPath).isDirectory();
    })
    .sort()
    .reverse();

  if (entries.length === 0) {
    console.log("No transcripts found");
    return;
  }

  console.log("📝 Transcripts:\n");
  
  for (const entry of entries) {
    const transcriptPath = join(paths.transcripts, entry, "transcript.md");
    const audioPath = join(paths.transcripts, entry, "audio.wav");
    
    const hasTranscript = existsSync(transcriptPath);
    const hasAudio = existsSync(audioPath);
    
    let size = "";
    if (hasTranscript) {
      const stats = statSync(transcriptPath);
      size = `${Math.round(stats.size / 1024)}KB`;
    }
    
    const icons = [
      hasTranscript ? "📝" : "  ",
      hasAudio ? "🎵" : "  ",
    ].join("");
    
    console.log(`  ${icons} ${entry} ${size}`);
  }
  
  console.log(`\nTotal: ${entries.length} recording(s)`);
  console.log(`Location: ${paths.transcripts}`);
}

function handleOpen(args: string[]): void {
  if (args.length === 0) {
    console.error("Error: Transcript name required");
    console.error("Usage: transcriptor open <name>");
    process.exit(1);
  }

  const name = args[0];
  
  // Find matching directory
  const entries = readdirSync(paths.transcripts);
  const match = entries.find(e => e.includes(name));
  
  if (!match) {
    console.error(`No transcript found matching "${name}"`);
    process.exit(1);
  }

  const transcriptPath = join(paths.transcripts, match, "transcript.md");
  
  if (!existsSync(transcriptPath)) {
    console.error(`Transcript not found: ${transcriptPath}`);
    process.exit(1);
  }

  // Open with default app
  const proc = Bun.spawn(["open", transcriptPath]);
  console.log(`Opening ${transcriptPath}`);
}

function handleConfig(args: string[]): void {
  const config = loadConfig();
  
  if (args.length === 0) {
    console.log("Current configuration:\n");
    for (const [key, value] of Object.entries(config)) {
      console.log(`  ${key}: ${value}`);
    }
    console.log(`\nConfig file: ${paths.config}`);
    return;
  }

  if (args[0] === "set" && args.length >= 3) {
    const key = args[1] as keyof Config;
    const value = args.slice(2).join(" ");
    
    if (!(key in config)) {
      console.error(`Unknown config key: ${key}`);
      process.exit(1);
    }

    // Type coercion
    if (typeof config[key] === "number") {
      (config as any)[key] = parseInt(value);
    } else if (typeof config[key] === "boolean") {
      (config as any)[key] = value === "true";
    } else {
      (config as any)[key] = value;
    }

    saveConfig(config);
    console.log(`Set ${key} = ${value}`);
  } else {
    console.error("Usage: transcriptor config set <key> <value>");
  }
}

async function handleDoctor(): Promise<void> {
  console.log("🔍 Checking installation...\n");
  
  const checks: Array<{ name: string; ok: boolean; path?: string }> = [];

  // Check directories
  ensureDirectories();
  checks.push({ name: "Config directory", ok: existsSync(paths.transcriptor), path: paths.transcriptor });
  checks.push({ name: "Transcripts directory", ok: existsSync(paths.transcripts), path: paths.transcripts });
  checks.push({ name: "Bin directory", ok: existsSync(paths.bin), path: paths.bin });

  // Check binaries
  checks.push({ name: "Audio capture binary", ok: existsSync(paths.audioBin), path: paths.audioBin });
  checks.push({ name: "Menu bar indicator", ok: existsSync(paths.indicatorBin), path: paths.indicatorBin });

  // Check whisper
  const whisper = await checkWhisperInstalled();
  checks.push({ name: "whisper.cpp", ok: whisper.installed, path: join(paths.whisperBin, "main") });
  
  const config = loadConfig();
  const modelPath = join(paths.whisperModel, `ggml-${config.whisperModel}.bin`);
  checks.push({ name: `Whisper model (${config.whisperModel})`, ok: whisper.model, path: modelPath });

  // Check ffmpeg
  let ffmpegOk = false;
  try {
    const proc = Bun.spawn(["which", "ffmpeg"], { stdout: "pipe" });
    const output = await new Response(proc.stdout).text();
    ffmpegOk = output.trim().length > 0;
  } catch {}
  checks.push({ name: "ffmpeg", ok: ffmpegOk, path: "system" });

  // Print results
  let allOk = true;
  for (const check of checks) {
    const icon = check.ok ? "✅" : "❌";
    console.log(`  ${icon} ${check.name}`);
    if (!check.ok && check.path) {
      console.log(`     Missing: ${check.path}`);
      allOk = false;
    }
  }

  console.log("");
  
  if (allOk) {
    console.log("✅ All checks passed! Ready to record.");
  } else {
    console.log("❌ Some components are missing. Run the install script:");
    console.log("   ./install.sh");
  }
}

function handleClean(): void {
  const config = loadConfig();
  
  if (!existsSync(paths.transcripts)) {
    console.log("No transcripts to clean");
    return;
  }

  const now = Date.now();
  const audioMaxAge = config.audioRetentionDays * 24 * 60 * 60 * 1000;
  const transcriptMaxAge = config.transcriptRetentionDays * 24 * 60 * 60 * 1000;

  let audioDeleted = 0;
  let transcriptsDeleted = 0;

  const entries = readdirSync(paths.transcripts);
  
  for (const entry of entries) {
    const entryPath = join(paths.transcripts, entry);
    const stats = statSync(entryPath);
    
    if (!stats.isDirectory()) continue;
    
    const age = now - stats.mtimeMs;
    
    // Check if we should delete the whole directory
    if (age > transcriptMaxAge) {
      rmSync(entryPath, { recursive: true });
      transcriptsDeleted++;
      continue;
    }
    
    // Check if we should delete just the audio
    const audioPath = join(entryPath, "audio.wav");
    if (existsSync(audioPath) && age > audioMaxAge) {
      unlinkSync(audioPath);
      audioDeleted++;
    }
    
    // Clean up chunks directory if it exists
    const chunksPath = join(entryPath, "chunks");
    if (existsSync(chunksPath)) {
      rmSync(chunksPath, { recursive: true });
    }
  }

  console.log(`Cleaned up:`);
  console.log(`  📝 ${transcriptsDeleted} old transcript(s) deleted`);
  console.log(`  🎵 ${audioDeleted} old audio file(s) deleted`);
}

// Main
const args = process.argv.slice(2);
const command = args[0] ?? "help";
const commandArgs = args.slice(1);

switch (command) {
  case "start":
    await handleStart(commandArgs);
    break;
  case "stop":
    await handleStop();
    break;
  case "status":
    handleStatus();
    break;
  case "list":
    handleList();
    break;
  case "open":
    handleOpen(commandArgs);
    break;
  case "config":
    handleConfig(commandArgs);
    break;
  case "doctor":
    await handleDoctor();
    break;
  case "clean":
    handleClean();
    break;
  case "help":
  case "--help":
  case "-h":
    printHelp();
    break;
  case "version":
  case "--version":
  case "-v":
    console.log(`transcriptor v${VERSION}`);
    break;
  default:
    console.error(`Unknown command: ${command}`);
    printHelp();
    process.exit(1);
}
