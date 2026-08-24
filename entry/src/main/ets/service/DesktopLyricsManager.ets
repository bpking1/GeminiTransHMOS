import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { AppSettings } from '../model/AppSettings';
import { Log } from '../util/Logger';
import { SessionListener, SessionState, TranslationSession } from './TranslationSession';

export type LyricsActiveChangeListener = (active: boolean) => void;

const MAX_LRC_LINES: number = 300;
const MAX_LYRIC_LINE_UNITS: number = 16;
const PIN_BACK_MS: number = 60;
const METADATA_PUSH_INTERVAL_MS: number = 800;
const TRANSCRIPT_FLUSH_DELAY_MS: number = 350;
const TICK_INTERVAL_MS: number = 1000;
const PLACEHOLDER_LYRIC: string = '[00:00.00]字幕将实时显示在这里';

function formatLrcTimestamp(elapsedMs: number): string {
  const safeMs: number = Math.max(0, Math.floor(elapsedMs));
  const minutes: number = Math.floor(safeMs / 60000);
  const seconds: number = Math.floor((safeMs % 60000) / 1000);
  const centiseconds: number = Math.floor((safeMs % 1000) / 10);
  const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
  const ss: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
  const xx: string = centiseconds < 10 ? `0${centiseconds}` : `${centiseconds}`;
  return `[${mm}:${ss}.${xx}]`;
}

function normalizeLyricText(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

function displayUnits(text: string): number {
  let units: number = 0;
  for (let index = 0; index < text.length; index++) {
    units += text.charCodeAt(index) > 0xff ? 1 : 0.5;
  }
  return units;
}

function isWordChar(code: number): boolean {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

function joinLyricText(left: string, right: string): string {
  if (left.length === 0) {
    return right;
  }
  if (right.length === 0) {
    return left;
  }
  if (isWordChar(left.charCodeAt(left.length - 1)) && isWordChar(right.charCodeAt(0))) {
    return `${left} ${right}`;
  }
  return left + right;
}

export class DesktopLyricsManager {
  private static instance: DesktopLyricsManager | undefined = undefined;

  private session: avSession.AVSession | undefined = undefined;
  private active: boolean = false;
  private activeChangeListeners: LyricsActiveChangeListener[] = [];
  private transcriptHookInstalled: boolean = false;
  private flushScheduled: boolean = false;
  private tickTimer: number = -1;

  private virtualStartMs: number = 0;
  private lrcLines: string[] = [];
  private consumedTextLength: number = 0;
  private pendingText: string = '';
  private currentLineText: string = '';
  private currentLineStartMs: number = 0;
  private lineSealed: boolean = true;
  private lastEntryStartMs: number = -1;
  private lastPushElapsedMs: number = -(METADATA_PUSH_INTERVAL_MS + 1);
  private currentSettings: AppSettings = new AppSettings();

  static getInstance(): DesktopLyricsManager {
    if (!DesktopLyricsManager.instance) {
      DesktopLyricsManager.instance = new DesktopLyricsManager();
    }
    return DesktopLyricsManager.instance;
  }

  isActive(): boolean {
    return this.active;
  }

  addActiveChangeListener(listener: LyricsActiveChangeListener): void {
    if (!this.activeChangeListeners.includes(listener)) {
      this.activeChangeListeners.push(listener);
    }
    listener(this.active);
  }

  removeActiveChangeListener(listener: LyricsActiveChangeListener): void {
    const index: number = this.activeChangeListeners.indexOf(listener);
    if (index >= 0) {
      this.activeChangeListeners.splice(index, 1);
    }
  }

  private setActive(active: boolean): void {
    if (this.active === active) {
      return;
    }
    this.active = active;
    for (let index = 0; index < this.activeChangeListeners.length; index++) {
      this.activeChangeListeners[index](active);
    }
  }

  updateSettings(settings: AppSettings): void {
    this.currentSettings = settings;
  }

  async isSupported(): Promise<boolean> {
    try {
      return await avSession.isDesktopLyricSupported();
    } catch (error) {
      Log.warn(`isDesktopLyricSupported check failed: ${JSON.stringify(error)}`);
      return false;
    }
  }

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.active) {
      return;
    }
    const supported: boolean = await this.isSupported();
    if (!supported) {
      throw new Error('当前系统不支持桌面歌词组件（需要 HarmonyOS 6.1.0 / API 23+）');
    }
    try {
      Log.info('DesktopLyricsManager: starting desktop lyrics session...');
      const type: avSession.AVSessionType = 'audio';
      const session: avSession.AVSession = await avSession.createAVSession(context, 'translation_desktop_lyrics', type);
      this.session = session;

      session.onDesktopLyricVisibilityChanged((visible: boolean): void => {
        Log.info(`DesktopLyric visibility changed: ${visible}`);
      });
      session.onDesktopLyricStateChanged((state: avSession.DesktopLyricState): void => {
        Log.info(`DesktopLyric state changed: isLocked=${state.isLocked}`);
      });

      await session.enableDesktopLyric(true);

      this.resetTimeline();
      await session.activate();
      await this.pushMetadata(true);
      await this.refreshPosition();
      await session.setDesktopLyricVisible(true);

      this.startTicker();
      this.setupTranscriptHook();
      this.setActive(true);
      Log.info('DesktopLyricsManager: desktop lyrics started');
    } catch (error) {
      await this.releaseSession();
      const message: string = error instanceof Error ? error.message : JSON.stringify(error);
      Log.error(`DesktopLyricsManager: start failed: ${message}`);
      throw new Error(`启动桌面歌词失败：${message}`);
    }
  }

  async stop(): Promise<void> {
    if (!this.active && !this.session) {
      return;
    }
    Log.info('DesktopLyricsManager: stopping desktop lyrics...');
    this.stopTicker();
    this.setActive(false);
    await this.releaseSession();
  }

  private resetTimeline(): void {
    this.virtualStartMs = Date.now();
    this.lrcLines = [];
    this.consumedTextLength = 0;
    this.pendingText = '';
    this.currentLineText = '';
    this.currentLineStartMs = 0;
    this.lineSealed = true;
    this.lastEntryStartMs = -1;
    this.lastPushElapsedMs = -(METADATA_PUSH_INTERVAL_MS + 1);
  }

  private async releaseSession(): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    this.session = undefined;
    if (!session) {
      return;
    }
    try {
      await session.setDesktopLyricVisible(false);
    } catch (error) {
      Log.warn(`setDesktopLyricVisible(false) failed: ${JSON.stringify(error)}`);
    }
    try {
      await session.enableDesktopLyric(false);
    } catch (error) {
      Log.warn(`enableDesktopLyric(false) failed: ${JSON.stringify(error)}`);
    }
    try {
      await session.destroy();
      Log.info('DesktopLyricsManager: AVSession destroyed');
    } catch (error) {
      Log.warn(`AVSession destroy failed: ${JSON.stringify(error)}`);
    }
  }

  private buildPlayingState(): avSession.AVPlaybackState {
    const elapsed: number = Date.now() - this.virtualStartMs;
    // The system lyric window renders "current line + next line". Pin the
    // reported position just before the newest entry so the previous line is
    // treated as current and the growing line is shown as the next preview.
    let pinMs: number = Math.max(0, elapsed);
    if (this.lastEntryStartMs >= 0) {
      pinMs = this.lrcLines.length > 1
        ? Math.max(0, this.lastEntryStartMs - PIN_BACK_MS)
        : this.lastEntryStartMs;
    }
    const position: avSession.PlaybackPosition = {
      elapsedTime: pinMs,
      updateTime: Date.now()
    };
    const playbackState: avSession.AVPlaybackState = {
      state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
      speed: 0,
      position: position
    };
    return playbackState;
  }

  private async refreshPosition(): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    if (!session) {
      return;
    }
    try {
      await session.setAVPlaybackState(this.buildPlayingState());
    } catch (error) {
      Log.warn(`setAVPlaybackState failed: ${JSON.stringify(error)}`);
    }
  }

  private async pushMetadata(force: boolean): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    if (!session) {
      return;
    }
    const elapsed: number = Date.now() - this.virtualStartMs;
    if (!force && elapsed - this.lastPushElapsedMs < METADATA_PUSH_INTERVAL_MS) {
      return;
    }
    this.lastPushElapsedMs = elapsed;
    const lrcContent: string = this.lrcLines.length > 0 ? this.lrcLines.join('\n') : PLACEHOLDER_LYRIC;
    const metadata: avSession.AVMetadata = {
      assetId: 'gemini_live_translation_captions',
      title: '实时翻译字幕',
      artist: 'Gemini Live',
      lyric: lrcContent
    };
    try {
      await session.setAVMetadata(metadata);
    } catch (error) {
      Log.warn(`setAVMetadata failed: ${JSON.stringify(error)}`);
    }
  }

  private flushPending(force: boolean): void {
    if (!this.active || !this.session) {
      return;
    }
    const text: string = TranslationSession.getInstance().getOutputTranscript();
    if (text.length < this.consumedTextLength) {
      this.resetTimeline();
    }
    if (text.length > this.consumedTextLength) {
      this.pendingText += text.substring(this.consumedTextLength);
      this.consumedTextLength = text.length;
    }
    const chunk: string = normalizeLyricText(this.pendingText);
    if (chunk.length > 0) {
      this.pendingText = '';
      this.appendToLyricLine(chunk);
    }
    this.pushMetadata(force);
  }

  private appendToLyricLine(chunk: string): void {
    if (this.lineSealed || this.lrcLines.length === 0) {
      this.currentLineStartMs = Date.now() - this.virtualStartMs;
      this.lastEntryStartMs = this.currentLineStartMs;
      this.currentLineText = chunk;
      this.lineSealed = false;
      this.lrcLines.push(`${formatLrcTimestamp(this.currentLineStartMs)}${this.currentLineText}`);
      if (this.lrcLines.length > MAX_LRC_LINES) {
        this.lrcLines.splice(0, this.lrcLines.length - MAX_LRC_LINES);
      }
    } else {
      this.currentLineText = joinLyricText(this.currentLineText, chunk);
      const stamp: string = formatLrcTimestamp(this.currentLineStartMs);
      this.lrcLines[this.lrcLines.length - 1] = `${stamp}${this.currentLineText}`;
    }
    if (displayUnits(this.currentLineText) >= MAX_LYRIC_LINE_UNITS) {
      this.lineSealed = true;
      this.currentLineText = '';
    }
  }

  private startTicker(): void {
    this.stopTicker();
    this.tickTimer = setInterval(() => {
      this.refreshPosition();
      this.flushPending(false);
    }, TICK_INTERVAL_MS);
  }

  private stopTicker(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private scheduleFlush(): void {
    if (this.flushScheduled) {
      return;
    }
    this.flushScheduled = true;
    setTimeout(() => {
      this.flushScheduled = false;
      this.flushPending(false);
    }, TRANSCRIPT_FLUSH_DELAY_MS);
  }

  private setupTranscriptHook(): void {
    if (this.transcriptHookInstalled) {
      return;
    }
    this.transcriptHookInstalled = true;
    const listener: SessionListener = {
      onState: (state: SessionState, status: string): void => {},
      onTranscript: (input: string, output: string): void => {
        this.scheduleFlush();
      },
      onError: (message: string): void => {}
    };
    TranslationSession.getInstance().addListener(listener);
  }
}
