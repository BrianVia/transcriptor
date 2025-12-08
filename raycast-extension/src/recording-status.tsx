import { showHUD, getPreferenceValues } from "@raycast/api";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

interface Preferences {
  transcriptorPath: string;
}

export default async function RecordingStatus() {
  const { transcriptorPath } = getPreferenceValues<Preferences>();
  const cli = transcriptorPath || "transcriptor";

  try {
    const { stdout } = await execAsync(`${cli} status`);
    
    if (stdout.includes("Recording:")) {
      // Parse the output
      const lines = stdout.trim().split("\n");
      const nameLine = lines.find(l => l.includes("Recording:"));
      const durationLine = lines.find(l => l.includes("Duration:"));
      
      const name = nameLine?.split("Recording:")[1]?.trim() || "Unknown";
      const duration = durationLine?.split("Duration:")[1]?.trim() || "";
      
      await showHUD(`🎙️ Recording: ${name} (${duration})`);
    } else {
      await showHUD("Not recording");
    }
  } catch {
    await showHUD("❌ Transcriptor not available");
  }
}
