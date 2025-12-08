import { spawn, type Subprocess } from "bun";
import { join } from "path";
import { existsSync, mkdirSync, readdirSync, unlinkSync, writeFileSync, appendFileSync, readFileSync } from "fs";
import { paths, loadConfig, loadState, saveState, clearState } from "./config";
import { transcribeChunk } from "./transcriber";

let audioProcess: Subprocess | null = null;
let chunkInterval: Timer | null = null;
let currentChunkNumber = 0;
let currentOutputDir = "";
let currentMeetingName = "";
let isStopping = false;

function formatDate(date: Date): string {
  return date.toISOString().split("T")[0];
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function formatTimestamp(seconds: number): string {
  const hours = Math.floor(seconds / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;

  if (hours > 0) {
    return `${hours}:${mins.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
  }
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

function formatTimeShort(date: Date): string {
  return date.toLocaleTimeString("en-US", {
    hour: "numeric",
    minute: "2-digit",
    hour12: true
  });
}

export async function startRecording(meetingName: string): Promise<void> {
  const state = loadState();

  if (state.isRecording) {
    console.error("Already recording! Stop the current recording first.");
    process.exit(1);
  }

  if (!existsSync(paths.audioBin)) {
    console.error(`Audio capture binary not found at ${paths.audioBin}`);
    console.error("Run the install script first: ./install.sh");
    process.exit(1);
  }

  const config = loadConfig();
  const now = new Date();
  const slug = slugify(meetingName);
  const dirName = `${formatDate(now)}_${slug}`;

  currentOutputDir = join(paths.transcripts, dirName);
  currentMeetingName = meetingName;
  currentChunkNumber = 0;
  isStopping = false;

  mkdirSync(join(currentOutputDir, "chunks"), { recursive: true });

  // Initialize transcript with YAML frontmatter
  const transcriptPath = join(currentOutputDir, "transcript.md");
  writeFileSync(
    transcriptPath,
    `---
title: "${meetingName}"
date: ${formatDate(now)}
started: ${formatTimeShort(now)}
ended:
duration:
---

# ${meetingName}

`
  );

  console.log(`📁 Output: ${currentOutputDir}`);
  console.log(`📝 Transcript: ${transcriptPath}`);

  await startChunk();

  chunkInterval = setInterval(async () => {
    await rotateChunk();
  }, config.chunkDurationSeconds * 1000);

  saveState({
    isRecording: true,
    meetingName,
    startTime: now.toISOString(),
    outputDir: currentOutputDir,
    audioPid: audioProcess?.pid ?? null,
    indicatorPid: null,
  });

  console.log(`\n🎙️  Recording "${meetingName}"...`);
  console.log(`   Chunks every ${config.chunkDurationSeconds}s → whisper transcription`);
  console.log(`   Press Ctrl+C to stop\n`);

  process.on("SIGINT", () => stopRecording());
  process.on("SIGTERM", () => stopRecording());

  const stopWatcher = setInterval(() => {
    if (existsSync(paths.stopSignal)) {
      unlinkSync(paths.stopSignal);
      clearInterval(stopWatcher);
      stopRecording();
    }
  }, 500);
}

async function startChunk(): Promise<void> {
  currentChunkNumber++;
  const chunkPath = join(currentOutputDir, "chunks", `chunk_${currentChunkNumber.toString().padStart(4, "0")}.wav`);

  audioProcess = spawn([paths.audioBin, "--output", chunkPath], {
    stdout: "ignore",
    stderr: "pipe",
  });

  console.log(`   📼 Chunk ${currentChunkNumber} started`);
}

async function rotateChunk(): Promise<void> {
  const prevChunkNumber = currentChunkNumber;
  const prevChunkPath = join(currentOutputDir, "chunks", `chunk_${prevChunkNumber.toString().padStart(4, "0")}.wav`);

  if (audioProcess) {
    audioProcess.kill("SIGTERM");
    await audioProcess.exited;
    audioProcess = null;
  }

  await startChunk();
  transcribeChunkAsync(prevChunkPath, prevChunkNumber);
}

async function transcribeChunkAsync(chunkPath: string, chunkNumber: number): Promise<void> {
  const config = loadConfig();
  const startSeconds = (chunkNumber - 1) * config.chunkDurationSeconds;

  try {
    console.log(`   🔄 Transcribing chunk ${chunkNumber}...`);
    const text = await transcribeChunk(chunkPath);

    if (text.trim()) {
      const timestamp = formatTimestamp(startSeconds);
      const transcriptPath = join(currentOutputDir, "transcript.md");
      appendFileSync(transcriptPath, `**${timestamp}** ${text.trim()}\n\n`);
      console.log(`   ✅ Chunk ${chunkNumber} transcribed`);
    } else {
      console.log(`   ⏭️  Chunk ${chunkNumber} was silent`);
    }
  } catch (error) {
    console.error(`   ❌ Failed to transcribe chunk ${chunkNumber}:`, error);
  }
}

export async function stopRecording(): Promise<void> {
  // Prevent multiple stop calls
  if (isStopping) return;
  isStopping = true;

  const state = loadState();

  if (!state.isRecording) {
    console.log("Not currently recording.");
    return;
  }

  // Clear state immediately to prevent re-entry
  clearState();

  console.log("\n⏹️  Stopping recording...");

  if (chunkInterval) {
    clearInterval(chunkInterval);
    chunkInterval = null;
  }

  if (audioProcess) {
    audioProcess.kill("SIGTERM");
    await audioProcess.exited;
    audioProcess = null;
  }

  if (state.audioPid) {
    try { process.kill(state.audioPid, "SIGTERM"); } catch {}
  }

  // Determine output directory
  const outputDir = currentOutputDir || state.outputDir;
  if (!outputDir) {
    console.log("No output directory found.");
    process.exit(0);
  }

  // Transcribe final chunk
  if (currentChunkNumber > 0) {
    const finalChunkPath = join(outputDir, "chunks", `chunk_${currentChunkNumber.toString().padStart(4, "0")}.wav`);
    if (existsSync(finalChunkPath)) {
      await transcribeChunkAsync(finalChunkPath, currentChunkNumber);
    }
  } else if (state.outputDir) {
    currentOutputDir = state.outputDir;
    const chunksDir = join(currentOutputDir, "chunks");
    if (existsSync(chunksDir)) {
      const chunks = readdirSync(chunksDir).filter(f => f.endsWith(".wav")).sort();
      if (chunks.length > 0) {
        const lastChunk = chunks[chunks.length - 1];
        const chunkNum = parseInt(lastChunk.match(/chunk_(\d+)/)?.[1] ?? "0");
        await transcribeChunkAsync(join(chunksDir, lastChunk), chunkNum);
      }
    }
  }

  // Finalize transcript - update frontmatter with end time and duration
  const transcriptPath = join(outputDir, "transcript.md");
  const endTime = new Date();
  const startTime = state.startTime ? new Date(state.startTime) : endTime;
  const durationSeconds = Math.floor((endTime.getTime() - startTime.getTime()) / 1000);

  if (existsSync(transcriptPath)) {
    let content = readFileSync(transcriptPath, "utf-8");

    // Update frontmatter
    content = content.replace(/^ended: *$/m, `ended: ${formatTimeShort(endTime)}`);
    content = content.replace(/^duration: *$/m, `duration: ${formatTimestamp(durationSeconds)}`);

    writeFileSync(transcriptPath, content);
  }

  await mergeAudioChunks(outputDir);

  console.log(`\n✅ Recording saved to ${outputDir}`);
  console.log(`   📝 Transcript: ${transcriptPath}`);

  process.exit(0);
}

async function mergeAudioChunks(outputDir: string): Promise<void> {
  const config = loadConfig();
  const chunksDir = join(outputDir, "chunks");

  if (!existsSync(chunksDir)) return;

  const chunks = readdirSync(chunksDir)
    .filter(f => f.endsWith(".wav"))
    .sort()
    .map(f => join(chunksDir, f));

  if (chunks.length === 0) return;

  const listPath = join(outputDir, "chunks.txt");
  writeFileSync(listPath, chunks.map(c => `file '${c}'`).join("\n"));

  const outputPath = join(outputDir, "audio.wav");

  try {
    const proc = spawn(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listPath, "-c", "copy", outputPath], {
      stdout: "ignore",
      stderr: "ignore",
    });
    await proc.exited;

    if (existsSync(outputPath)) {
      console.log(`   🎵 Audio merged: audio.wav`);

      if (config.deleteAudioAfterTranscript) {
        for (const chunk of chunks) {
          unlinkSync(chunk);
        }
        unlinkSync(listPath);
      }
    }
  } catch {
    console.log("   ⚠️  Could not merge audio (ffmpeg not available?)");
  }
}

export function getStatus(): { recording: boolean; meetingName?: string; duration?: string } {
  const state = loadState();

  if (!state.isRecording || !state.startTime) {
    return { recording: false };
  }

  const startTime = new Date(state.startTime);
  const durationSeconds = Math.floor((Date.now() - startTime.getTime()) / 1000);

  return {
    recording: true,
    meetingName: state.meetingName ?? undefined,
    duration: formatTimestamp(durationSeconds),
  };
}
