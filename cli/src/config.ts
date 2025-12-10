import { homedir } from "os";
import { join } from "path";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";

export interface Config {
  audioRetentionDays: number;
  transcriptRetentionDays: number;
  deleteAudioAfterTranscript: boolean;
  whisperModel: string;
  chunkDurationSeconds: number;
  // Calendar integration
  calendarEnabled: boolean;
  autoStartRecording: boolean;
  reminderMinutesBefore: number;
  onlyVideoMeetings: boolean;
  excludedCalendars: string[];
  excludedTitlePatterns: string[];
}

export interface RecordingState {
  isRecording: boolean;
  meetingName: string | null;
  startTime: string | null;
  outputDir: string | null;
  audioPid: number | null;
  indicatorPid: number | null;
}

const TRANSCRIPTOR_DIR = join(homedir(), ".transcriptor");
const CONFIG_PATH = join(TRANSCRIPTOR_DIR, "config.json");
const STATE_PATH = join(TRANSCRIPTOR_DIR, "state.json");
const BIN_DIR = join(TRANSCRIPTOR_DIR, "bin");
const TRANSCRIPTS_DIR = join(homedir(), "transcripts");

export const paths = {
  transcriptor: TRANSCRIPTOR_DIR,
  config: CONFIG_PATH,
  state: STATE_PATH,
  bin: BIN_DIR,
  transcripts: TRANSCRIPTS_DIR,
  whisperBin: join(BIN_DIR, "whisper-cpp"),
  whisperModel: join(BIN_DIR, "models"),
  audioBin: join(BIN_DIR, "transcriptor-audio"),
  indicatorBin: join(BIN_DIR, "transcriptor-indicator"),
  stopSignal: join(TRANSCRIPTOR_DIR, "stop-signal"),
};

const defaultConfig: Config = {
  audioRetentionDays: 7,
  transcriptRetentionDays: 90,
  deleteAudioAfterTranscript: false,
  whisperModel: "large-v3-turbo",
  chunkDurationSeconds: 30,
  // Calendar integration
  calendarEnabled: true,
  autoStartRecording: true,
  reminderMinutesBefore: 1,
  onlyVideoMeetings: false,
  excludedCalendars: [],
  excludedTitlePatterns: ["Focus", "Deep Work", "Do Not Disturb", "Blocked", "Busy", "Lunch", "Break", "OOO", "Out of Office", "Personal", "Hold"],
};

const defaultState: RecordingState = {
  isRecording: false,
  meetingName: null,
  startTime: null,
  outputDir: null,
  audioPid: null,
  indicatorPid: null,
};

export function ensureDirectories(): void {
  const dirs = [TRANSCRIPTOR_DIR, BIN_DIR, TRANSCRIPTS_DIR, paths.whisperModel];
  for (const dir of dirs) {
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
  }
}

export function loadConfig(): Config {
  ensureDirectories();
  if (existsSync(CONFIG_PATH)) {
    try {
      return { ...defaultConfig, ...JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) };
    } catch {
      return defaultConfig;
    }
  }
  saveConfig(defaultConfig);
  return defaultConfig;
}

export function saveConfig(config: Config): void {
  ensureDirectories();
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}

export function loadState(): RecordingState {
  ensureDirectories();
  if (existsSync(STATE_PATH)) {
    try {
      return { ...defaultState, ...JSON.parse(readFileSync(STATE_PATH, "utf-8")) };
    } catch {
      return defaultState;
    }
  }
  return defaultState;
}

export function saveState(state: RecordingState): void {
  ensureDirectories();
  writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

export function clearState(): void {
  saveState(defaultState);
}
