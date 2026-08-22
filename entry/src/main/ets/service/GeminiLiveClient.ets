import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { AppSettings } from '../model/AppSettings';

class AudioTranscriptionConfig {
}

interface TranslationConfig {
  targetLanguageCode: string;
  echoTargetLanguage: boolean;
}

interface GenerationConfig {
  responseModalities: string[];
  inputAudioTranscription: AudioTranscriptionConfig;
  outputAudioTranscription: AudioTranscriptionConfig;
  translationConfig: TranslationConfig;
}

interface SetupConfig {
  model: string;
  generationConfig: GenerationConfig;
}

interface SetupPayload {
  setup: SetupConfig;
}

interface AudioBlob {
  data: string;
  mimeType: string;
}

interface RealtimeInput {
  audio: AudioBlob;
}

interface AudioPayload {
  realtimeInput: RealtimeInput;
}

interface AudioStreamEndInput {
  audioStreamEnd: boolean;
}

interface AudioStreamEndPayload {
  realtimeInput: AudioStreamEndInput;
}

interface TranscriptMessage {
  text?: string;
}

interface InlineDataMessage {
  data?: string;
  mimeType?: string;
}

interface PartMessage {
  inlineData?: InlineDataMessage;
  text?: string;
}

interface ModelTurnMessage {
  parts?: PartMessage[];
}

interface ServerContentMessage {
  inputTranscription?: TranscriptMessage;
  outputTranscription?: TranscriptMessage;
  modelTurn?: ModelTurnMessage;
  interrupted?: boolean;
}

interface ApiErrorMessage {
  message?: string;
}

interface GeminiServerMessage {
  setupComplete?: Object;
  serverContent?: ServerContentMessage;
  error?: ApiErrorMessage;
}

export interface GeminiLiveCallbacks {
  onStatus: (status: string) => void;
  onInputTranscript: (text: string) => void;
  onOutputTranscript: (text: string) => void;
  onAudio: (data: Uint8Array) => void;
  onInterrupted: () => void;
  onDisconnected: (reason: string) => void;
}

export class GeminiLiveClient {
  private socket: webSocket.WebSocket | undefined = undefined;
  private callbacks: GeminiLiveCallbacks | undefined = undefined;
  private settings: AppSettings | undefined = undefined;
  private base64: util.Base64Helper = new util.Base64Helper();
  private open: boolean = false;
  private ready: boolean = false;
  private intentionalClose: boolean = false;
  private disconnectNotified: boolean = false;
  private connectTimer: number = -1;
  private readyResolve: (() => void) | undefined = undefined;
  private readyReject: ((reason: Error) => void) | undefined = undefined;

  setCallbacks(callbacks: GeminiLiveCallbacks): void {
    this.callbacks = callbacks;
  }

  async connect(settings: AppSettings): Promise<void> {
    await this.stop();
    this.settings = settings;
    this.intentionalClose = false;
    this.disconnectNotified = false;
    this.open = false;
    this.ready = false;

    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = socket;
    this.bindEvents(socket);

    const readyPromise: Promise<void> = new Promise<void>((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
      this.connectTimer = setTimeout(() => {
        this.failConnection('连接 Gemini 超时');
      }, 20000);
    });

    const url: string = this.buildWebSocketUrl(settings.apiBase, settings.apiKey);
    this.callbacks?.onStatus('正在连接 Gemini…');
    try {
      await socket.connect(url);
    } catch (error) {
      this.failConnection(`无法建立网络连接：${JSON.stringify(error)}`);
    }
    return readyPromise;
  }

  sendAudio(pcm16: Uint8Array): void {
    if (!this.ready || this.socket === undefined || pcm16.length === 0) {
      return;
    }
    const audioBlob: AudioBlob = {
      data: this.base64.encodeToStringSync(pcm16, util.Type.BASIC),
      mimeType: 'audio/pcm;rate=16000'
    };
    const realtimeInput: RealtimeInput = { audio: audioBlob };
    const payload: AudioPayload = { realtimeInput: realtimeInput };
    this.socket.send(JSON.stringify(payload)).catch((error: BusinessError) => {
      this.callbacks?.onStatus(`发送音频失败：${error.message}`);
    });
  }

  async stop(): Promise<void> {
    this.intentionalClose = true;
    this.clearConnectTimer();

    if (!this.ready && this.readyReject !== undefined) {
      this.readyReject(new Error('连接已取消'));
    }
    this.readyResolve = undefined;
    this.readyReject = undefined;
    this.ready = false;
    this.open = false;

    const current: webSocket.WebSocket | undefined = this.socket;
    this.socket = undefined;
    if (current === undefined) {
      return;
    }

    try {
      const realtimeInput: AudioStreamEndInput = { audioStreamEnd: true };
      const endPayload: AudioStreamEndPayload = { realtimeInput: realtimeInput };
      await current.send(JSON.stringify(endPayload));
    } catch (error) {
      console.info(`Audio stream end was not sent: ${JSON.stringify(error)}`);
    }

    try {
      await current.close({ code: 1000, reason: 'User stopped translation' });
    } catch (error) {
      console.info(`WebSocket close failed: ${JSON.stringify(error)}`);
    }
  }

  private bindEvents(socket: webSocket.WebSocket): void {
    socket.on('open', (error: BusinessError, value: Object) => {
      if (this.socket !== socket) {
        return;
      }
      if (error) {
        this.failConnection(`WebSocket 打开失败：${error.message}`);
        return;
      }
      this.open = true;
      this.callbacks?.onStatus('正在初始化翻译模型…');
      this.sendSetup();
      console.info(`Gemini WebSocket opened: ${JSON.stringify(value)}`);
    });

    socket.on('message', (error: BusinessError, value: string | ArrayBuffer) => {
      if (this.socket !== socket) {
        return;
      }
      if (error) {
        this.callbacks?.onStatus(`接收数据失败：${error.message}`);
        return;
      }
      if (typeof value === 'string') {
        this.handleMessage(value);
      }
    });

    socket.on('close', (error: BusinessError, value: webSocket.CloseResult) => {
      if (this.socket !== socket) {
        return;
      }
      this.open = false;
      this.ready = false;
      this.clearConnectTimer();
      if (!this.intentionalClose) {
        const detail: string = error
          ? error.message
          : `${value.code} ${value.reason}`.trim();
        this.rejectReady(`连接已断开：${detail}`);
        this.notifyDisconnected(`连接已断开：${detail}`);
      }
    });

    socket.on('error', (error: BusinessError) => {
      if (this.socket !== socket) {
        return;
      }
      if (!this.intentionalClose) {
        this.failConnection(`Gemini 连接错误：${error.message}`);
      }
    });
  }

  private sendSetup(): void {
    const currentSettings: AppSettings | undefined = this.settings;
    const currentSocket: webSocket.WebSocket | undefined = this.socket;
    if (currentSettings === undefined || currentSocket === undefined || !this.open) {
      return;
    }

    const translationConfig: TranslationConfig = {
      targetLanguageCode: currentSettings.targetLanguage,
      echoTargetLanguage: currentSettings.playbackEnabled
    };
    const generationConfig: GenerationConfig = {
      responseModalities: ['AUDIO'],
      inputAudioTranscription: new AudioTranscriptionConfig(),
      outputAudioTranscription: new AudioTranscriptionConfig(),
      translationConfig: translationConfig
    };
    const setupConfig: SetupConfig = {
      model: 'models/gemini-3.5-live-translate-preview',
      generationConfig: generationConfig
    };
    const payload: SetupPayload = { setup: setupConfig };
    currentSocket.send(JSON.stringify(payload)).catch((error: BusinessError) => {
      this.failConnection(`模型初始化失败：${error.message}`);
    });
  }

  private handleMessage(raw: string): void {
    try {
      const message: GeminiServerMessage = JSON.parse(raw) as GeminiServerMessage;
      if (message.error !== undefined) {
        this.failConnection(`Gemini 返回错误：${message.error.message ?? '未知错误'}`);
        return;
      }

      if (message.setupComplete !== undefined && !this.ready) {
        this.ready = true;
        this.clearConnectTimer();
        this.callbacks?.onStatus('翻译已就绪');
        if (this.readyResolve !== undefined) {
          this.readyResolve();
        }
        this.readyResolve = undefined;
        this.readyReject = undefined;
        return;
      }

      const content: ServerContentMessage | undefined = message.serverContent;
      if (content === undefined) {
        return;
      }
      if (content.interrupted === true) {
        this.callbacks?.onInterrupted();
      }

      const inputText: string = content.inputTranscription?.text ?? '';
      if (inputText.length > 0) {
        this.callbacks?.onInputTranscript(inputText);
      }

      const outputText: string = content.outputTranscription?.text ?? '';
      if (outputText.length > 0) {
        this.callbacks?.onOutputTranscript(outputText);
      }

      const parts: PartMessage[] = content.modelTurn?.parts ?? [];
      for (let index = 0; index < parts.length; index++) {
        const part: PartMessage = parts[index];
        const inlineData: InlineDataMessage | undefined = part.inlineData;
        if (inlineData?.data !== undefined && inlineData.data.length > 0) {
          this.callbacks?.onAudio(this.base64.decodeSync(inlineData.data, util.Type.BASIC));
        }
        // Output transcription is authoritative. Fall back to a text part only
        // when this server message contains no transcription field.
        const partText: string = part.text ?? '';
        if (outputText.length === 0 && partText.length > 0) {
          this.callbacks?.onOutputTranscript(partText);
        }
      }
    } catch (error) {
      this.callbacks?.onStatus(`解析 Gemini 数据失败：${JSON.stringify(error)}`);
    }
  }

  private buildWebSocketUrl(apiBase: string, apiKey: string): string {
    let base: string = apiBase.trim();
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.startsWith('https://')) {
      base = `wss://${base.substring('https://'.length)}`;
    } else if (base.startsWith('http://')) {
      base = `ws://${base.substring('http://'.length)}`;
    } else if (!base.startsWith('wss://') && !base.startsWith('ws://')) {
      const local: boolean = base.startsWith('localhost') || base.startsWith('127.0.0.1') ||
        base.startsWith('192.168.') || base.startsWith('10.');
      base = `${local ? 'ws' : 'wss'}://${base}`;
    }

    const endpoint: string = '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
    if (base.includes(endpoint)) {
      return `${base}${base.includes('?') ? '&' : '?'}key=${encodeURIComponent(apiKey)}`;
    }
    return `${base}${endpoint}?key=${encodeURIComponent(apiKey)}`;
  }

  private failConnection(message: string): void {
    this.callbacks?.onStatus(message);
    this.rejectReady(message);
    this.notifyDisconnected(message);
  }

  private rejectReady(message: string): void {
    this.clearConnectTimer();
    if (this.readyReject !== undefined) {
      this.readyReject(new Error(message));
    }
    this.readyResolve = undefined;
    this.readyReject = undefined;
  }

  private notifyDisconnected(message: string): void {
    if (this.disconnectNotified) {
      return;
    }
    this.disconnectNotified = true;
    this.callbacks?.onDisconnected(message);
  }

  private clearConnectTimer(): void {
    if (this.connectTimer >= 0) {
      clearTimeout(this.connectTimer);
      this.connectTimer = -1;
    }
  }
}
