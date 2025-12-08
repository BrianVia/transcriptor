import {
  Action,
  ActionPanel,
  List,
  showToast,
  Toast,
  getPreferenceValues,
  Icon,
  Color,
} from "@raycast/api";
import { useState, useEffect } from "react";
import { readdirSync, statSync, existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

interface Transcript {
  name: string;
  path: string;
  transcriptPath: string;
  audioPath: string | null;
  hasTranscript: boolean;
  hasAudio: boolean;
  date: Date;
  preview: string;
}

interface Preferences {
  transcriptorPath: string;
}

function formatDate(date: Date): string {
  return date.toLocaleDateString(undefined, {
    weekday: "short",
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function getTranscriptPreview(transcriptPath: string): string {
  try {
    const content = readFileSync(transcriptPath, "utf-8");
    // Skip the metadata header and get first bit of actual content
    const lines = content.split("\n");
    const contentStart = lines.findIndex(l => l.startsWith("**["));
    if (contentStart === -1) return "No content yet";
    
    const previewLines = lines.slice(contentStart, contentStart + 3);
    return previewLines.join(" ").substring(0, 200).replace(/\*\*/g, "") + "...";
  } catch {
    return "Unable to read";
  }
}

export default function ViewTranscripts() {
  const [transcripts, setTranscripts] = useState<Transcript[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    loadTranscripts();
  }, []);

  function loadTranscripts() {
    const transcriptsDir = join(homedir(), "transcripts");
    
    if (!existsSync(transcriptsDir)) {
      setTranscripts([]);
      setIsLoading(false);
      return;
    }

    try {
      const entries = readdirSync(transcriptsDir)
        .filter(name => {
          const fullPath = join(transcriptsDir, name);
          return statSync(fullPath).isDirectory();
        })
        .map(name => {
          const path = join(transcriptsDir, name);
          const transcriptPath = join(path, "transcript.md");
          const audioPath = join(path, "audio.wav");
          const hasTranscript = existsSync(transcriptPath);
          const hasAudio = existsSync(audioPath);
          const stats = statSync(path);

          return {
            name,
            path,
            transcriptPath,
            audioPath: hasAudio ? audioPath : null,
            hasTranscript,
            hasAudio,
            date: stats.mtime,
            preview: hasTranscript ? getTranscriptPreview(transcriptPath) : "No transcript",
          };
        })
        .sort((a, b) => b.date.getTime() - a.date.getTime());

      setTranscripts(entries);
    } catch (error) {
      showToast({
        style: Toast.Style.Failure,
        title: "Failed to load transcripts",
        message: String(error),
      });
    }

    setIsLoading(false);
  }

  function getDisplayName(name: string): string {
    // Convert "2024-12-08_weekly-standup" to "Weekly Standup"
    const parts = name.split("_");
    if (parts.length > 1) {
      return parts.slice(1).join(" ").replace(/-/g, " ").replace(/\b\w/g, l => l.toUpperCase());
    }
    return name;
  }

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search transcripts...">
      {transcripts.length === 0 ? (
        <List.EmptyView
          title="No Transcripts"
          description="Start a recording to create your first transcript"
          icon={Icon.Document}
        />
      ) : (
        transcripts.map(transcript => (
          <List.Item
            key={transcript.name}
            title={getDisplayName(transcript.name)}
            subtitle={formatDate(transcript.date)}
            accessories={[
              transcript.hasTranscript ? { icon: { source: Icon.Document, tintColor: Color.Green } } : {},
              transcript.hasAudio ? { icon: { source: Icon.Music, tintColor: Color.Blue } } : {},
            ]}
            actions={
              <ActionPanel>
                <ActionPanel.Section title="Open">
                  {transcript.hasTranscript && (
                    <Action.Open
                      title="Open Transcript"
                      target={transcript.transcriptPath}
                      icon={Icon.Document}
                    />
                  )}
                  {transcript.hasAudio && (
                    <Action.Open
                      title="Play Audio"
                      target={transcript.audioPath!}
                      icon={Icon.Music}
                    />
                  )}
                  <Action.ShowInFinder path={transcript.path} />
                </ActionPanel.Section>
                <ActionPanel.Section title="Actions">
                  {transcript.hasTranscript && (
                    <Action.CopyToClipboard
                      title="Copy Transcript"
                      content={readFileSync(transcript.transcriptPath, "utf-8")}
                      shortcut={{ modifiers: ["cmd"], key: "c" }}
                    />
                  )}
                  <Action
                    title="Refresh"
                    icon={Icon.ArrowClockwise}
                    onAction={loadTranscripts}
                    shortcut={{ modifiers: ["cmd"], key: "r" }}
                  />
                </ActionPanel.Section>
              </ActionPanel>
            }
          />
        ))
      )}
    </List>
  );
}
