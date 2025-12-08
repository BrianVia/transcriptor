import { Action, ActionPanel, Form, showToast, Toast, getPreferenceValues, closeMainWindow } from "@raycast/api";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

interface Preferences {
  transcriptorPath: string;
}

export default function StartRecording() {
  async function handleSubmit(values: { meetingName: string }) {
    const { transcriptorPath } = getPreferenceValues<Preferences>();
    const cli = transcriptorPath || "transcriptor";

    if (!values.meetingName.trim()) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Meeting name required",
      });
      return;
    }

    try {
      // Check if already recording
      const { stdout } = await execAsync(`${cli} status`);
      if (stdout.includes("Recording:")) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Already recording",
          message: "Stop the current recording first",
        });
        return;
      }
    } catch {
      // Status check failed, probably not installed
    }

    try {
      await closeMainWindow();
      
      // Start recording in background
      // Using osascript to run in a new terminal tab that stays open
      const escapedName = values.meetingName.replace(/"/g, '\\"');
      const script = `
        tell application "Terminal"
          do script "${cli} start \\"${escapedName}\\""
          activate
        end tell
      `;
      
      await execAsync(`osascript -e '${script.replace(/'/g, "'\\''")}'`);

      await showToast({
        style: Toast.Style.Success,
        title: "Recording started",
        message: values.meetingName,
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Failed to start recording",
        message: String(error),
      });
    }
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Start Recording" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        id="meetingName"
        title="Meeting Name"
        placeholder="Weekly Standup"
        autoFocus
      />
      <Form.Description
        title="Info"
        text="Recording will start in a Terminal window. Use 'Stop Recording' command or Ctrl+C to stop."
      />
    </Form>
  );
}
