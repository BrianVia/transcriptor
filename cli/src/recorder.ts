import { spawn, type Subprocess } from "bun";
import { join } from "path";
import { existsSync, mkdirSync, readdirSync, unlinkSync, writeFileSync, appendFileSync, readFileSync } from "fs";
import { paths, loadConfig, loadState, saveState, clearState } from "./config";
import { transcribeChunk } from "./transcriber";
import { formatDate, slugify, stripDatePrefix, formatTimestamp, formatTimeShort } from "./utils";

let audioProcess: Subprocess | null = null;
let chunkInterval: Timer | null = null;
let currentChunkNumber = 0;
let currentOutputDir = "";
let currentMeetingName = "";
let isStopping = false;
let stopWatcher: Timer | null = null;
const pendingTranscriptions = new Map<string, Promise<void>>();

export async function startRecording(meetingName: string): Promise<void> {
  const state = loadState();

  if (state.isRecording) {
    console.error("Already recording! Stop the current recording first.");
    process.exit(1);
  }

  if (!existsSync(paths.audioApp)) {
    console.error(`Audio capture app not found at ${paths.audioApp}`);
    console.error("Run the install script first: ./install.sh");
    process.exit(1);
  }

  const config = loadConfig();
  const now = new Date();
  const slug = slugify(stripDatePrefix(meetingName)) || "recording";
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

  await startAudioProcess();

  chunkInterval = setInterval(async () => {
    await rotateChunk();
  }, config.chunkDurationSeconds * 1000);

  saveState({
    isRecording: true,
    meetingName,
    startTime: now.toISOString(),
    outputDir: currentOutputDir,
    audioPid: audioPid ?? audioProcess?.pid ?? null,
    indicatorPid: null,
  });

  console.log(`\n🎙️  Recording "${meetingName}"...`);
  console.log(`   Chunks every ${config.chunkDurationSeconds}s → whisper transcription`);
  console.log(`   Press Ctrl+C to stop\n`);

  process.on("SIGINT", () => stopRecording());
  process.on("SIGTERM", () => stopRecording());

  stopWatcher = setInterval(() => {
    if (existsSync(paths.stopSignal)) {
      unlinkSync(paths.stopSignal);
      clearInterval(stopWatcher);
      stopWatcher = null;
      stopRecording();
    }
  }, 500);
}

let audioPid: number | null = null;
let processedChunks = new Set<string>();
let chunkWatcher: Timer | null = null;

async function startAudioProcess(): Promise<void> {
  currentChunkNumber = 1;
  const chunkPrefix = join(currentOutputDir, "chunks", "chunk_");

  // Clean up stale files
  try { unlinkSync(paths.audioPidFile); } catch {}
  try { unlinkSync(paths.completedChunksFile); } catch {}

  // Launch via `open -a` so macOS properly registers the app with Launch Services / TCC.
  // This is what makes screen recording permission persist across sessions.
  audioProcess = spawn(["open", "-a", paths.audioApp, "--args", "--chunk-prefix", chunkPrefix, "--mic"], {
    stdout: "ignore",
    stderr: "ignore",
  });

  // Wait for PID file to appear (audio process writes it on startup)
  const maxWait = 10_000;
  const start = Date.now();
  while (Date.now() - start < maxWait) {
    if (existsSync(paths.audioPidFile)) {
      const pidStr = readFileSync(paths.audioPidFile, "utf-8").trim();
      audioPid = parseInt(pidStr);
      if (!isNaN(audioPid)) break;
    }
    await Bun.sleep(100);
  }

  if (!audioPid) {
    console.error("   ❌ Audio capture process failed to start");
    process.exit(1);
  }

  // Watch the completed-chunks file for transcription
  processedChunks.clear();
  chunkWatcher = setInterval(() => {
    if (!existsSync(paths.completedChunksFile)) return;
    const content = readFileSync(paths.completedChunksFile, "utf-8");
    const lines = content.split("\n").filter(l => l.trim());
    for (const chunkPath of lines) {
      if (processedChunks.has(chunkPath)) continue;
      processedChunks.add(chunkPath);
      const match = chunkPath.match(/chunk_(\d+)\.wav$/);
      const chunkNum = match ? parseInt(match[1]) : 0;
      if (chunkNum > 0 && existsSync(chunkPath)) {
        queueTranscription(chunkPath, chunkNum);
      }
    }
  }, 500);

  console.log(`   📼 Recording started (pid: ${audioPid})`);
}

async function rotateChunk(): Promise<void> {
  if (!audioPid) return;

  // Send SIGUSR1 to rotate chunk — no process restart, no permission re-check
  currentChunkNumber++;
  try {
    process.kill(audioPid, "SIGUSR1");
  } catch {
    console.error(`   ❌ Failed to signal audio process (pid ${audioPid})`);
  }
  console.log(`   📼 Chunk ${currentChunkNumber} started`);
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

function queueTranscription(chunkPath: string, chunkNumber: number): Promise<void> {
  const existing = pendingTranscriptions.get(chunkPath);
  if (existing) {
    return existing;
  }

  const task = transcribeChunkAsync(chunkPath, chunkNumber)
    .finally(() => {
      pendingTranscriptions.delete(chunkPath);
    });

  pendingTranscriptions.set(chunkPath, task);
  return task;
}

async function waitForPendingTranscriptions(): Promise<void> {
  if (pendingTranscriptions.size === 0) {
    return;
  }

  await Promise.allSettled(Array.from(pendingTranscriptions.values()));
}

export async function stopRecording(): Promise<void> {
  // Prevent multiple stop calls
  if (isStopping) return;
  isStopping = true;

  const state = loadState();
  const hasLocalRecording = Boolean(currentOutputDir || audioPid || audioProcess);

  if (!state.isRecording && !hasLocalRecording) {
    console.log("Not currently recording.");
    isStopping = false;
    return;
  }

  console.log("\n⏹️  Stopping recording...");

  if (chunkInterval) {
    clearInterval(chunkInterval);
    chunkInterval = null;
  }

  if (stopWatcher) {
    clearInterval(stopWatcher);
    stopWatcher = null;
  }

  if (chunkWatcher) {
    clearInterval(chunkWatcher);
    chunkWatcher = null;
  }

  // Stop the audio process via PID (it was launched via `open`, not as a direct child)
  const pidToKill = audioPid ?? state.audioPid;
  if (pidToKill) {
    try { process.kill(pidToKill, "SIGTERM"); } catch {}
    // Wait briefly for it to finalize the last chunk
    await Bun.sleep(500);
  }
  audioPid = null;
  audioProcess = null;

  // Determine output directory
  const outputDir = currentOutputDir || state.outputDir;
  if (!outputDir) {
    console.log("No output directory found.");
    process.exit(0);
  }

  // Transcribe any remaining chunks (including the final one written on SIGTERM)
  if (existsSync(paths.completedChunksFile)) {
    const content = readFileSync(paths.completedChunksFile, "utf-8");
    const lines = content.split("\n").filter(l => l.trim());
    for (const chunkPath of lines) {
      if (processedChunks.has(chunkPath)) continue;
      processedChunks.add(chunkPath);
      const match = chunkPath.match(/chunk_(\d+)\.wav$/);
      const chunkNum = match ? parseInt(match[1]) : 0;
      if (chunkNum > 0 && existsSync(chunkPath)) {
        await queueTranscription(chunkPath, chunkNum);
      }
    }
  } else if (currentChunkNumber > 0) {
    // Fallback: transcribe by known chunk number
    const finalChunkPath = join(outputDir, "chunks", `chunk_${currentChunkNumber.toString().padStart(4, "0")}.wav`);
    if (existsSync(finalChunkPath) && !processedChunks.has(finalChunkPath)) {
      processedChunks.add(finalChunkPath);
      await queueTranscription(finalChunkPath, currentChunkNumber);
    }
  } else if (state.outputDir) {
    // Fallback for external stop: find last chunk on disk
    currentOutputDir = state.outputDir;
    const chunksDir = join(currentOutputDir, "chunks");
    if (existsSync(chunksDir)) {
      const chunks = readdirSync(chunksDir).filter(f => f.endsWith(".wav")).sort();
      if (chunks.length > 0) {
        const lastChunk = chunks[chunks.length - 1];
        const chunkNum = parseInt(lastChunk.match(/chunk_(\d+)/)?.[1] ?? "0");
        const lastChunkPath = join(chunksDir, lastChunk);
        processedChunks.add(lastChunkPath);
        await queueTranscription(lastChunkPath, chunkNum);
      }
    }
  }

  await waitForPendingTranscriptions();

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

  clearState();

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
