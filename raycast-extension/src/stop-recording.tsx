import { showToast, Toast, getPreferenceValues } from "@raycast/api";
import { exec } from "child_process";
import { promisify } from "util";
import { existsSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const execAsync = promisify(exec);

interface Preferences {
  transcriptorPath: string;
}

export default async function StopRecording() {
  const { transcriptorPath } = getPreferenceValues<Preferences>();
  const cli = transcriptorPath || "transcriptor";

  try {
    // Check status first
    const { stdout } = await execAsync(`${cli} status`);
    
    if (!stdout.includes("Recording:")) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Not recording",
        message: "No active recording to stop",
      });
      return;
    }

    // Write stop signal file (the indicator watches for this)
    const stopSignalPath = join(homedir(), ".transcriptor", "stop-signal");
    writeFileSync(stopSignalPath, "stop");

    await showToast({
      style: Toast.Style.Success,
      title: "Stopping recording",
      message: "Transcription will complete shortly",
    });
  } catch (error) {
    // Try writing stop signal anyway
    try {
      const stopSignalPath = join(homedir(), ".transcriptor", "stop-signal");
      writeFileSync(stopSignalPath, "stop");
      
      await showToast({
        style: Toast.Style.Success,
        title: "Stop signal sent",
        message: "Recording should stop shortly",
      });
    } catch {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to stop recording",
        message: String(error),
      });
    }
  }
}
