import { spawn } from "bun";
import { existsSync } from "fs";
import { join } from "path";
import { paths, loadConfig } from "./config";

export async function transcribeChunk(audioPath: string): Promise<string> {
  if (!existsSync(audioPath)) {
    throw new Error(`Audio file not found: ${audioPath}`);
  }

  const config = loadConfig();
  const whisperMain = join(paths.whisperBin, "main");
  const modelPath = join(paths.whisperModel, `ggml-${config.whisperModel}.bin`);

  if (!existsSync(whisperMain)) {
    throw new Error(`whisper.cpp not found at ${whisperMain}. Run install script.`);
  }

  if (!existsSync(modelPath)) {
    throw new Error(`Whisper model not found at ${modelPath}. Run install script.`);
  }

  const proc = spawn([
    whisperMain,
    "-m", modelPath,
    "-f", audioPath,
    "--no-timestamps",
    "--no-prints",
    "-l", "en",
    "--threads", "4",
  ], {
    stdout: "pipe",
    stderr: "pipe",
  });

  const output = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  
  await proc.exited;

  if (proc.exitCode !== 0) {
    throw new Error(`whisper.cpp failed: ${stderr}`);
  }

  return output.trim();
}

export async function checkWhisperInstalled(): Promise<{ installed: boolean; model: boolean }> {
  const config = loadConfig();
  const whisperMain = join(paths.whisperBin, "main");
  const modelPath = join(paths.whisperModel, `ggml-${config.whisperModel}.bin`);

  return {
    installed: existsSync(whisperMain),
    model: existsSync(modelPath),
  };
}
