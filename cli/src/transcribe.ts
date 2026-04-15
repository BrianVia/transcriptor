import { spawn } from "bun";
import { existsSync, mkdirSync, writeFileSync, rmSync, statSync } from "fs";
import { join, basename, extname } from "path";
import { paths, loadConfig, ensureDirectories } from "./config";
import { checkWhisperInstalled } from "./transcriber";
import { slugify, formatDate, formatTimestamp } from "./utils";

const AUDIO_EXTENSIONS = new Set([".mp3", ".wav", ".m4a", ".flac", ".ogg", ".webm"]);

export function isYouTubeUrl(input: string): boolean {
  return /^https?:\/\/(www\.)?(youtube\.com|youtu\.be)\//.test(input);
}

export function isAudioFile(input: string): boolean {
  return AUDIO_EXTENSIONS.has(extname(input).toLowerCase());
}

async function checkBinary(name: string): Promise<boolean> {
  try {
    const proc = spawn(["which", name], { stdout: "pipe", stderr: "pipe" });
    const output = await new Response(proc.stdout).text();
    await proc.exited;
    return output.trim().length > 0;
  } catch {
    return false;
  }
}

async function ensureDependencies(needsYtDlp: boolean): Promise<void> {
  if (!await checkBinary("ffmpeg")) {
    console.error("ffmpeg is required but not found. Install it with: brew install ffmpeg");
    process.exit(1);
  }
  if (needsYtDlp && !await checkBinary("yt-dlp")) {
    console.error("yt-dlp is required for YouTube URLs. Install it with: brew install yt-dlp");
    process.exit(1);
  }
  const whisper = await checkWhisperInstalled();
  if (!whisper.installed) {
    console.error("whisper.cpp not found. Run ./install.sh");
    process.exit(1);
  }
  if (!whisper.model) {
    const config = loadConfig();
    console.error(`Whisper model '${config.whisperModel}' not found. Run ./install.sh`);
    process.exit(1);
  }
}

async function getYouTubeTitle(url: string): Promise<string> {
  const proc = spawn(["yt-dlp", "--print", "title", url], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const title = await new Response(proc.stdout).text();
  await proc.exited;
  if (proc.exitCode !== 0) {
    throw new Error("Failed to get YouTube video title");
  }
  return title.trim();
}

async function downloadYouTube(url: string, outputDir: string): Promise<string> {
  const outputPath = join(outputDir, "download.%(ext)s");
  const proc = spawn(["yt-dlp", "-x", "--audio-format", "wav", "-o", outputPath, url], {
    stdout: "inherit",
    stderr: "inherit",
  });
  await proc.exited;
  if (proc.exitCode !== 0) {
    throw new Error("yt-dlp download failed");
  }
  // yt-dlp may output as .wav or keep original format
  const wavPath = join(outputDir, "download.wav");
  if (existsSync(wavPath)) return wavPath;
  // Check for other formats yt-dlp might have produced
  const { readdirSync } = await import("fs");
  const files = readdirSync(outputDir).filter(f => f.startsWith("download."));
  if (files.length === 0) throw new Error("No downloaded file found");
  return join(outputDir, files[0]);
}

async function convertToWhisperFormat(inputPath: string, outputPath: string): Promise<void> {
  const proc = spawn([
    "ffmpeg", "-i", inputPath,
    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
    outputPath, "-y",
  ], {
    stdout: "pipe",
    stderr: "pipe",
  });
  await proc.exited;
  if (proc.exitCode !== 0) {
    const stderr = await new Response(proc.stderr).text();
    throw new Error(`ffmpeg conversion failed: ${stderr}`);
  }
}

async function getAudioDuration(filePath: string): Promise<number> {
  const proc = spawn([
    "ffprobe", "-i", filePath,
    "-show_entries", "format=duration",
    "-v", "quiet", "-of", "csv=p=0",
  ], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const output = await new Response(proc.stdout).text();
  await proc.exited;
  return Math.round(parseFloat(output.trim()));
}

async function transcribeFullFile(wavPath: string): Promise<string> {
  const config = loadConfig();
  const whisperMain = join(paths.whisperBin, "main");
  const modelPath = join(paths.whisperModel, `ggml-${config.whisperModel}.bin`);

  const proc = spawn([
    whisperMain,
    "-m", modelPath,
    "-f", wavPath,
    "--suppress-nst",
    "-l", "en",
    "--threads", "8",
    "-pp",
  ], {
    stdout: "pipe",
    stderr: "inherit",
  });

  const output = await new Response(proc.stdout).text();
  await proc.exited;

  if (proc.exitCode !== 0) {
    throw new Error("whisper.cpp transcription failed");
  }

  return output.trim();
}

function createOutputDir(name: string): string {
  const date = formatDate(new Date());
  const slug = slugify(name);
  let dirName = `${date}_${slug}`;
  let fullPath = join(paths.transcripts, dirName);

  // Handle collisions
  let suffix = 2;
  while (existsSync(fullPath)) {
    dirName = `${date}_${slug}-${suffix}`;
    fullPath = join(paths.transcripts, dirName);
    suffix++;
  }

  mkdirSync(fullPath, { recursive: true });
  return fullPath;
}

export async function handleTranscribe(args: string[]): Promise<void> {
  if (args.length === 0) {
    console.error("Usage: transcriptor transcribe <youtube-url|audio-file>");
    process.exit(1);
  }

  const input = args[0];
  const isUrl = isYouTubeUrl(input);
  const isFile = !isUrl;

  if (isFile && !existsSync(input)) {
    console.error(`File not found: ${input}`);
    process.exit(1);
  }

  if (isFile && !isAudioFile(input)) {
    console.error(`Unsupported audio format: ${extname(input)}`);
    console.error(`Supported: ${[...AUDIO_EXTENSIONS].join(", ")}`);
    process.exit(1);
  }

  ensureDirectories();
  await ensureDependencies(isUrl);

  const tempDir = join("/tmp", `transcriptor-${Date.now()}`);
  mkdirSync(tempDir, { recursive: true });

  try {
    let title: string;
    let sourceAudioPath: string;
    let sourceUrl: string | undefined;

    if (isUrl) {
      console.log("Fetching video info...");
      title = await getYouTubeTitle(input);
      console.log(`Title: ${title}`);
      console.log("Downloading audio...");
      sourceAudioPath = await downloadYouTube(input, tempDir);
      sourceUrl = input;
    } else {
      title = basename(input, extname(input));
      sourceAudioPath = input;
    }

    console.log("Converting to whisper format...");
    const wavPath = join(tempDir, "audio.wav");
    await convertToWhisperFormat(sourceAudioPath, wavPath);

    const duration = await getAudioDuration(wavPath);
    console.log(`Duration: ${formatTimestamp(duration)}`);

    const outputDir = createOutputDir(title);
    console.log(`Output: ${outputDir}`);

    console.log("Transcribing...");
    const transcript = await transcribeFullFile(wavPath);

    const frontmatter = [
      "---",
      `title: "${title}"`,
      `date: ${formatDate(new Date())}`,
      `source: ${isUrl ? "youtube" : "file"}`,
      ...(sourceUrl ? [`url: ${sourceUrl}`] : []),
      `duration: ${formatTimestamp(duration)}`,
      "---",
      "",
      `# ${title}`,
      "",
      transcript,
      "",
    ].join("\n");

    writeFileSync(join(outputDir, "transcript.md"), frontmatter);

    // Copy the WAV to the output dir
    const { copyFileSync } = await import("fs");
    copyFileSync(wavPath, join(outputDir, "audio.wav"));

    console.log(`\nDone! Transcript saved to ${join(outputDir, "transcript.md")}`);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}
