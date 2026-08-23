import { abilityAccessCtrl, common, PermissionRequestResult } from '@kit.AbilityKit';
import { AppSettings } from '../model/AppSettings';
import { Log } from '../util/Logger';
import {
  AudioCaptureSource,
  MicrophoneCapture,
  SystemAudioCapture
} from './AudioCaptureService';
import { CaptionFloatView } from './CaptionFloatView';
import { GeminiLiveCallbacks, GeminiLiveClient } from './GeminiLiveClient';
import { PcmAudioPlayer } from './PcmAudioPlayer';

export enum SessionState {
  IDLE = 'idle',
  STARTING = 'starting',
  LIVE = 'live',
  ERROR = 'error'
}

export interface SessionListener {
  onState: (state: SessionState, status: string) => void;
  onTranscript: (input: string, output: string) => void;
  onError: (message: string) => void;
}

function isCjkChar(c: string): boolean {
  if (!c || c.length === 0) {
    return false;
  }
  const code: number = c.charCodeAt(0);
  return (code >= 0x4E00 && code <= 0x9FFF) ||
         (code >= 0x3400 && code <= 0x4DBF) ||
         (code >= 0x3000 && code <= 0x303F) ||
         (code >= 0xFF00 && code <= 0xFFEF);
}

function smartConcat(prev: string, next: string): string {
  const p: string = prev.trim();
  const n: string = next.trim();
  if (p.length === 0) {
    return n;
  }
  if (n.length === 0) {
    return p;
  }
  const lastChar: string = p.charAt(p.length - 1);
  const firstChar: string = n.charAt(0);
  if (isCjkChar(lastChar) || isCjkChar(firstChar)) {
    return `${p}${n}`;
  }
  return `${p} ${n}`;
}

export class TranscriptBuffer {
  private committed: string = '';
  private draft: string = '';
  private readonly highWatermark: number;
  private readonly lowWatermark: number;

  constructor(highWatermark: number = 1000, lowWatermark: number = 500) {
    this.highWatermark = Math.max(200, highWatermark);
    this.lowWatermark = Math.max(100, Math.min(this.highWatermark - 100, lowWatermark));
  }

  update(fragment: string): string {
    const text: string = fragment.trim();
    if (text.length === 0) {
      return this.value();
    }

    if (this.draft.length > 0 && text.startsWith(this.draft)) {
      this.draft = text;
    } else {
      if (this.draft.length > 0) {
        this.committed = smartConcat(this.committed, this.draft);
      }
      this.draft = text;
    }

    // High-Low Watermark Batch Trimming:
    // Only perform atomic sentence trimming when committed text crosses high watermark (e.g. 1000 chars)
    if (this.committed.length > this.highWatermark) {
      this.trimToLowWatermark();
    }
    return this.value();
  }

  private trimToLowWatermark(): void {
    const targetKeepLength: number = this.lowWatermark;
    if (this.committed.length <= targetKeepLength) {
      return;
    }

    const cutStartIdx: number = this.committed.length - targetKeepLength;
    let bestBoundary: number = cutStartIdx;
    let found: boolean = false;

    // Search backward up to 80 chars for a clean sentence boundary (。！？.!?\n)
    for (let i = cutStartIdx; i >= Math.max(0, cutStartIdx - 80); i--) {
      const ch: string = this.committed.charAt(i);
      if (ch === '。' || ch === '！' || ch === '？' || ch === '\n' || ch === '.' || ch === '!' || ch === '?') {
        bestBoundary = i + 1;
        found = true;
        break;
      }
    }

    // If not found, search forward up to 80 chars
    if (!found) {
      for (let i = cutStartIdx; i < Math.min(this.committed.length, cutStartIdx + 80); i++) {
        const ch: string = this.committed.charAt(i);
        if (ch === '。' || ch === '！' || ch === '？' || ch === '\n' || ch === '.' || ch === '!' || ch === '?') {
          bestBoundary = i + 1;
          found = true;
          break;
        }
      }
    }

    // Secondary fallback: search for comma / space / semicolon
    if (!found) {
      for (let i = cutStartIdx; i >= Math.max(0, cutStartIdx - 50); i--) {
        const ch: string = this.committed.charAt(i);
        if (ch === '，' || ch === '；' || ch === '、' || ch === ',' || ch === ';' || ch === ' ') {
          bestBoundary = i + 1;
          found = true;
          break;
        }
      }
    }

    this.committed = this.committed.substring(bestBoundary).trim();
  }

  value(): string {
    return smartConcat(this.committed, this.draft);
  }

  getRecentSubtitle(maxLines: number = 2, maxWeightPerLine: number = 15): string {
    const d: string = this.draft.trim();
    const c: string = this.committed.trim();
    const targetLines: number = Math.max(1, Math.min(5, maxLines));

    const combined: string = smartConcat(c, d);
    return buildRollingLines(combined, targetLines, maxWeightPerLine);
  }

  clear(): void {
    this.committed = '';
    this.draft = '';
  }
}

function getCharVisualWeight(c: string): number {
  if (!c || c.length === 0) {
    return 0;
  }
  const code: number = c.charCodeAt(0);
  // ASCII / Latin / Numbers / Half-width punctuation
  if (code <= 0x024F || (code >= 0x2000 && code <= 0x206F)) {
    return 0.55;
  }
  return 1.0;
}

function buildRollingLines(fullText: string, maxLines: number, maxWeightPerLine: number = 15): string {
  const clean: string = fullText.replace(/[\r\n]+/g, ' ').trim();
  if (clean.length === 0) {
    return '';
  }

  // Process recent tail of text for instant calculation
  const maxScanLength: number = Math.round(maxLines * maxWeightPerLine * 4);
  let scanText: string = clean;
  if (scanText.length > maxScanLength) {
    scanText = scanText.substring(scanText.length - maxScanLength).trim();
  }

  const lines: string[] = [];
  let currentLine: string = '';
  let currentWeight: number = 0;

  for (let i = 0; i < scanText.length; i++) {
    const ch: string = scanText.charAt(i);
    const w: number = getCharVisualWeight(ch);

    if (currentWeight + w > maxWeightPerLine && currentLine.length > 0) {
      lines.push(currentLine.trim());
      currentLine = ch;
      currentWeight = w;
    } else {
      currentLine += ch;
      currentWeight += w;
    }
  }

  if (currentLine.trim().length > 0) {
    lines.push(currentLine.trim());
  }

  if (lines.length === 0) {
    return '';
  }

  const startIdx: number = Math.max(0, lines.length - maxLines);
  const visibleLines: string[] = lines.slice(startIdx);
  return visibleLines.join('\n');
}

export class TranslationSession {
  private static readonly INSTANCE: TranslationSession = new TranslationSession();

  static getInstance(): TranslationSession {
    return TranslationSession.INSTANCE;
  }

  private readonly client: GeminiLiveClient = new GeminiLiveClient();
  private readonly player: PcmAudioPlayer = new PcmAudioPlayer();
  private capture: AudioCaptureSource | undefined = undefined;
  private readonly listeners: SessionListener[] = [];
  private state: SessionState = SessionState.IDLE;
  private status: string = '准备就绪';
  private running: boolean = false;
  private starting: boolean = false;
  private cleaningUp: boolean = false;
  private cleanupTask: Promise<void> | undefined = undefined;
  private playbackEnabled: boolean = false;
  private operationId: number = 0;
  private readonly inputBuffer: TranscriptBuffer = new TranscriptBuffer(800, 400);
  private readonly outputBuffer: TranscriptBuffer = new TranscriptBuffer(1000, 500);

  private constructor() {
    const callbacks: GeminiLiveCallbacks = {
      onStatus: (status: string): void => {
        this.status = status;
        this.publishState();
      },
      onInputTranscript: (text: string): void => {
        this.inputBuffer.update(text);
        this.publishTranscripts();
      },
      onOutputTranscript: (text: string): void => {
        this.outputBuffer.update(text);
        this.publishTranscripts();
      },
      onAudio: (data: Uint8Array): void => {
        if (this.playbackEnabled) {
          this.player.enqueue(data);
        }
      },
      onInterrupted: (): void => {
        this.player.clear();
      },
      onDisconnected: (reason: string): void => {
        // A failed connection rejects start() directly. Once a session is
        // running, a later disconnect must also tear down capture and playback.
        if (this.running && !this.cleaningUp) {
          this.handleUnexpectedDisconnect(reason);
        }
      }
    };
    this.client.setCallbacks(callbacks);
  }

  addListener(listener: SessionListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
    listener.onState(this.state, this.status);
    listener.onTranscript(this.inputBuffer.value(), this.outputBuffer.value());
  }

  removeListener(listener: SessionListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  setListener(listener: SessionListener | undefined): void {
    if (listener) {
      this.addListener(listener);
    }
  }

  async start(context: common.UIAbilityContext, settings: AppSettings): Promise<void> {
    if (this.running || this.starting || this.cleaningUp || this.cleanupTask !== undefined) {
      Log.warn(`TranslationSession start ignored: already running/starting/cleaning (running=${this.running}, starting=${this.starting})`);
      return;
    }
    settings.normalize();
    Log.info(`Starting TranslationSession: source=${settings.audioSource}, targetLang=${settings.targetLanguage}, apiBase=${settings.apiBase}, playback=${settings.playbackEnabled}`);

    if (settings.apiKey.length === 0) {
      this.setError('请先在设置中填写 Gemini API Key');
      return;
    }

    const currentOperation: number = ++this.operationId;
    this.starting = true;
    this.state = SessionState.STARTING;
    this.status = settings.audioSource === 'system' ? '准备系统内录…' : '请求麦克风权限…';
    this.publishState();

    try {
      Log.info(`Requesting audio/microphone permission for source: ${settings.audioSource}...`);
      const granted: boolean = await this.requestMicrophonePermission(context);
      Log.info(`Audio permission result: ${granted}`);
      if (!granted) {
        throw new Error('未获得录音/音频采集权限，请在系统弹窗中允许');
      }

      this.status = '正在连接 Gemini…';
      this.publishState();
      Log.info('Connecting GeminiLiveClient...');
      await this.client.connect(settings);
      if (currentOperation !== this.operationId) {
        Log.warn('Session operation changed during connect, cleaning up...');
        await this.cleanup();
        return;
      }

      const sendAudio = (chunk: Uint8Array): void => {
        this.client.sendAudio(chunk);
      };
      this.capture = settings.audioSource === 'system'
        ? new SystemAudioCapture(sendAudio)
        : new MicrophoneCapture(sendAudio);

      this.status = settings.audioSource === 'system'
        ? '正在启动系统内录…'
        : '正在启动麦克风…';
      this.publishState();
      Log.info(`Starting audio capture: ${settings.audioSource}...`);
      await this.capture.start();
      if (currentOperation !== this.operationId) {
        Log.warn('Session operation changed during capture start, cleaning up...');
        await this.cleanup();
        return;
      }

      this.playbackEnabled = settings.playbackEnabled;
      if (this.playbackEnabled) {
        Log.info(`Starting audio player (volume: ${settings.playbackVolume})...`);
        await this.player.start(settings.playbackVolume);
        if (currentOperation !== this.operationId) {
          Log.warn('Session operation changed during player start, cleaning up...');
          await this.cleanup();
          return;
        }
      }

      this.starting = false;
      this.running = true;
      this.state = SessionState.LIVE;
      this.status = settings.audioSource === 'system' ? '正在翻译系统声音' : '正在聆听并翻译';
      this.publishState();
      Log.info('Translation session is LIVE and active!');
    } catch (error) {
      if (currentOperation !== this.operationId) {
        return;
      }
      const message: string = this.errorText(error);
      Log.error(`TranslationSession start failed: ${message}`);
      await this.cleanup();
      this.setError(message);
    }
  }

  async stop(): Promise<void> {
    Log.info('Stopping TranslationSession...');
    ++this.operationId;
    if (!this.running && !this.starting && this.capture === undefined &&
      this.cleanupTask === undefined) {
      this.state = SessionState.IDLE;
      this.status = '准备就绪';
      this.publishState();
      return;
    }

    this.running = false;
    this.starting = false;
    this.state = SessionState.STARTING;
    this.status = '正在停止…';
    this.publishState();
    await this.cleanup();
    this.state = SessionState.IDLE;
    this.status = '已停止';
    this.publishState();
    Log.info('TranslationSession stopped successfully');
  }

  clearTranscripts(): void {
    this.inputBuffer.clear();
    this.outputBuffer.clear();
    this.publishTranscripts();
  }

  getInputTranscript(): string {
    return this.inputBuffer.value();
  }

  getOutputTranscript(): string {
    return this.outputBuffer.value();
  }

  getRecentOutputSubtitle(maxLines: number = 2, maxWeightPerLine: number = 15): string {
    return this.outputBuffer.getRecentSubtitle(maxLines, maxWeightPerLine);
  }

  getRecentInputSubtitle(maxLines: number = 2, maxWeightPerLine: number = 15): string {
    return this.inputBuffer.getRecentSubtitle(maxLines, maxWeightPerLine);
  }

  isActive(): boolean {
    return this.running || this.starting || this.cleaningUp || this.cleanupTask !== undefined;
  }

  private cleanup(): Promise<void> {
    if (this.cleanupTask !== undefined) {
      return this.cleanupTask;
    }
    this.cleanupTask = this.performCleanup();
    return this.cleanupTask;
  }

  private async performCleanup(): Promise<void> {
    this.cleaningUp = true;
    this.running = false;
    this.starting = false;
    try {
      const currentCapture: AudioCaptureSource | undefined = this.capture;
      this.capture = undefined;
      if (currentCapture !== undefined) {
        try {
          await currentCapture.stop();
        } catch (error) {
          console.warn(`Stopping audio capture failed: ${JSON.stringify(error)}`);
        }
      }
      try {
        await this.player.stop();
      } catch (error) {
        console.warn(`Stopping audio playback failed: ${JSON.stringify(error)}`);
      }
      try {
        await this.client.stop();
      } catch (error) {
        console.warn(`Closing Gemini session failed: ${JSON.stringify(error)}`);
      }
      this.playbackEnabled = false;
    } finally {
      this.cleaningUp = false;
      this.cleanupTask = undefined;
    }
  }

  private handleUnexpectedDisconnect(reason: string): void {
    Log.error(`handleUnexpectedDisconnect: ${reason}`);
    ++this.operationId;
    this.cleanup().then(() => {
      this.setError(reason);
    }).catch((error: Error) => {
      this.setError(`${reason}；清理资源失败：${error.message}`);
    });
  }

  private async requestMicrophonePermission(context: common.UIAbilityContext): Promise<boolean> {
    const atManager = abilityAccessCtrl.createAtManager();
    try {
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(
        context, ['ohos.permission.MICROPHONE']);
      return result.authResults.length > 0 && result.authResults[0] === 0;
    } catch (error) {
      Log.error(`Requesting microphone permission failed: ${JSON.stringify(error)}`);
      return false;
    }
  }

  private setError(message: string): void {
    Log.error(`Session error set: ${message}`);
    this.running = false;
    this.starting = false;
    this.state = SessionState.ERROR;
    this.status = message;
    this.publishState();
    for (let index = 0; index < this.listeners.length; index++) {
      this.listeners[index].onError(message);
    }
  }

  private publishState(): void {
    for (let index = 0; index < this.listeners.length; index++) {
      this.listeners[index].onState(this.state, this.status);
    }
  }

  private publishTranscripts(): void {
    const inVal = this.inputBuffer.value();
    const outVal = this.outputBuffer.value();
    for (let index = 0; index < this.listeners.length; index++) {
      this.listeners[index].onTranscript(inVal, outVal);
    }
    // Synchronize to FloatView
    CaptionFloatView.getInstance().update(
      this.getRecentInputSubtitle(2, 20),
      this.getRecentOutputSubtitle(2, 20)
    );
  }

  private errorText(error: Object): string {
    if (error instanceof Error) {
      return error.message;
    }
    return JSON.stringify(error) ?? '未知错误';
  }
}
