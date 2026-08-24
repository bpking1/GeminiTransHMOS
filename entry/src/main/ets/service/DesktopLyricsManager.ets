import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { AppSettings } from '../model/AppSettings';
import { Log } from '../util/Logger';
import { SessionListener, SessionState, TranslationSession } from './TranslationSession';

export type LyricsActiveChangeListener = (active: boolean) => void;

const METADATA_PUSH_INTERVAL_MS: number = 800;
const TRANSCRIPT_FLUSH_DELAY_MS: number = 350;
const TICK_INTERVAL_MS: number = 1000;
const PLACEHOLDER_LYRIC: string = '[00:00.00]字幕将实时显示在这里';
const MAX_LYRIC_LINE_UNITS: number = 16;
// The window renders "current line" bright and "next line" dim. We want the
// growing caption in the bright slot, so its fake timestamp sits slightly in
// the past, while the previous completed line gets a far-future stamp to stay
// in the dim preview slot.
const CURRENT_SLOT_BACK_MS: number = 1000;
const NEXT_SLOT_AHEAD_MS: number = 20000;

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
  private lastSeenText: string = '';
  private pendingText: string = '';
  private prevLine: string = '';
  private growingText: string = '';
  private metadataSeq: number = 0;
  private lastPushRealMs: number = 0;
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
    this.lastSeenText = '';
    this.pendingText = '';
    this.prevLine = '';
    this.growingText = '';
    this.lastPushRealMs = 0;
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
    const position: avSession.PlaybackPosition = {
      elapsedTime: Math.max(0, Date.now() - this.virtualStartMs),
      updateTime: Date.now()
    };
    const playbackState: avSession.AVPlaybackState = {
      state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
      speed: 1,
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

  private computeDelta(text: string): string {
    if (this.lastSeenText.length === 0) {
      return text;
    }
    if (text.startsWith(this.lastSeenText)) {
      return text.substring(this.lastSeenText.length);
    }
    // TranscriptBuffer trims old content from the front once it crosses its
    // high watermark, so match by longest suffix/prefix overlap instead of
    // plain length diffs (a length shrink is NOT a clear event).
    const maxK: number = Math.min(this.lastSeenText.length, text.length, 400);
    let best: number = 0;
    for (let k: number = maxK; k >= 1; k--) {
      if (this.lastSeenText.endsWith(text.substring(0, k))) {
        best = k;
        break;
      }
    }
    if (best === 0 && text.length < this.lastSeenText.length / 2) {
      // Wholesale replacement (e.g. clearTranscripts followed by new speech).
      Log.info('DesktopLyric transcript replaced wholesale, resetting timeline');
      this.resetTimeline();
      return text;
    }
    return text.substring(best);
  }

  private async pushMetadata(force: boolean): Promise<void> {
    const session: avSession.AVSession | undefined = this.session;
    if (!session) {
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastPushRealMs < METADATA_PUSH_INTERVAL_MS) {
      return;
    }
    this.lastPushRealMs = now;
    // Bump assetId on every push: the system caches lyric content by assetId,
    // so reusing the same id makes it ignore our LRC updates entirely.
    this.metadataSeq += 1;

    const elapsed: number = Math.max(0, now - this.virtualStartMs);
    let lyric: string = PLACEHOLDER_LYRIC;
    if (this.growingText.length > 0 || this.prevLine.length > 0) {
      const currentText: string = this.growingText.length > 0 ? this.growingText : this.prevLine;
      const lines: string[] = [
        `${formatLrcTimestamp(Math.max(0, elapsed - CURRENT_SLOT_BACK_MS))}${currentText}`
      ];
      if (this.prevLine.length > 0) {
        lines.push(`${formatLrcTimestamp(elapsed + NEXT_SLOT_AHEAD_MS)}${this.prevLine}`);
      }
      lyric = lines.join('\n');
    }

    const metadata: avSession.AVMetadata = {
      assetId: `translation_captions_${this.metadataSeq}`,
      title: '实时翻译字幕',
      artist: 'Gemini Live',
      lyric: lyric
    };
    try {
      await session.setAVMetadata(metadata);
      Log.info(`DesktopLyric metadata pushed: seq=${this.metadataSeq}, growing=${this.growingText.length}, prev=${this.prevLine.length}`);
    } catch (error) {
      Log.warn(`setAVMetadata failed: ${JSON.stringify(error)}`);
    }
  }

  private flushPending(force: boolean): void {
    if (!this.active || !this.session) {
      return;
    }
    const text: string = TranslationSession.getInstance().getOutputTranscript();
    if (text.trim().length === 0) {
      if (this.lastSeenText.trim().length > 0) {
        Log.info('DesktopLyric transcript cleared, resetting timeline');
        this.resetTimeline();
        this.pushMetadata(true);
      }
      return;
    }
    const delta: string = this.computeDelta(text);
    this.lastSeenText = text;
    const chunk: string = normalizeLyricText(this.pendingText.length > 0 ? this.pendingText + delta : delta);
    this.pendingText = '';
    if (chunk.length > 0) {
      this.growingText = joinLyricText(this.growingText, chunk);
      if (displayUnits(this.growingText) >= MAX_LYRIC_LINE_UNITS) {
        this.prevLine = this.growingText;
        this.growingText = '';
      }
    }
    this.pushMetadata(force);
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
