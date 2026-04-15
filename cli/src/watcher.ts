import { watch } from "fs";
import { existsSync, mkdirSync, readdirSync, readFileSync, unlinkSync, renameSync, statSync } from "fs";
import { join, extname } from "path";
import { paths, ensureDirectories } from "./config";
import { handleTranscribe, isYouTubeUrl, isAudioFile } from "./transcribe";

const DEBOUNCE_MS = 1500;

const processing = new Set<string>();
const debounceTimers = new Map<string, Timer>();

async function processFile(filePath: string, fileName: string): Promise<void> {
  if (processing.has(fileName)) return;
  processing.add(fileName);

  try {
    const ext = extname(fileName).toLowerCase();

    if (isAudioFile(fileName)) {
      console.log(`\nProcessing: ${fileName}`);
      await handleTranscribe([filePath]);
      unlinkSync(filePath);
      console.log(`Removed ${fileName} from inbox`);
    } else if (ext === ".txt") {
      const content = readFileSync(filePath, "utf-8").trim();
      if (isYouTubeUrl(content)) {
        console.log(`\nProcessing YouTube URL from: ${fileName}`);
        await handleTranscribe([content]);
        unlinkSync(filePath);
        console.log(`Removed ${fileName} from inbox`);
      } else {
        console.log(`Skipping ${fileName}: not a YouTube URL`);
      }
    } else {
      console.log(`Skipping ${fileName}: unsupported format`);
    }
  } catch (err) {
    const failedDir = join(paths.inbox, ".failed");
    mkdirSync(failedDir, { recursive: true });
    try {
      renameSync(filePath, join(failedDir, fileName));
      console.error(`Failed to process ${fileName}, moved to .failed/`);
    } catch {
      console.error(`Failed to process ${fileName}: ${err}`);
    }
  } finally {
    processing.delete(fileName);
  }
}

function scheduleProcess(fileName: string): void {
  if (debounceTimers.has(fileName)) {
    clearTimeout(debounceTimers.get(fileName)!);
  }

  debounceTimers.set(fileName, setTimeout(() => {
    debounceTimers.delete(fileName);
    const filePath = join(paths.inbox, fileName);
    if (!existsSync(filePath)) return;

    // Skip hidden files and directories
    if (fileName.startsWith(".")) return;

    try {
      const stat = statSync(filePath);
      if (!stat.isFile() || stat.size === 0) return;
    } catch {
      return;
    }

    processFile(filePath, fileName);
  }, DEBOUNCE_MS));
}

export async function handleWatch(): Promise<void> {
  ensureDirectories();
  mkdirSync(paths.inbox, { recursive: true });

  console.log(`Watching ${paths.inbox} for files to transcribe...`);
  console.log("Drop audio files (.mp3, .wav, .m4a, .flac, .ogg, .webm) or .txt files with YouTube URLs");
  console.log("Press Ctrl+C to stop\n");

  // Process any existing files in the inbox
  const existing = readdirSync(paths.inbox).filter(f => !f.startsWith("."));
  for (const fileName of existing) {
    const filePath = join(paths.inbox, fileName);
    try {
      if (statSync(filePath).isFile()) {
        scheduleProcess(fileName);
      }
    } catch {}
  }

  watch(paths.inbox, (eventType, fileName) => {
    if (!fileName || fileName.startsWith(".")) return;
    scheduleProcess(fileName);
  });

  process.on("SIGINT", () => {
    console.log("\nStopping watcher...");
    process.exit(0);
  });
  process.on("SIGTERM", () => process.exit(0));

  await new Promise(() => {});
}
