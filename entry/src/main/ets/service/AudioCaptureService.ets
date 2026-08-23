import { audio } from '@kit.AudioKit';
import { BusinessError } from '@kit.BasicServicesKit';
import playbackCaptureNative from 'libentry.so';
import { Log } from '../util/Logger';

export class PlaybackCapturerOptions implements audio.AudioCapturerOptions {
  streamInfo: audio.AudioStreamInfo = {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
    channels: audio.AudioChannel.CHANNEL_1,
    sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
    encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
  };
  capturerInfo: audio.AudioCapturerInfo = {
    source: (audio.SourceType.SOURCE_TYPE_PLAYBACK_CAPTURE ?? 3) as audio.SourceType,
    capturerFlags: 0
  };
  playbackCaptureMode?: number = 0x8001;
}

export interface PlaybackCaptureController {
  requestPlaybackCaptureStart?: (callback: (state: number) => void) => void;
}

export type PcmChunkHandler = (chunk: Uint8Array) => void;

class PcmChunker {
  private readonly chunkSize: number;
  private readonly handler: PcmChunkHandler;
  private pending: number[] = [];

  constructor(chunkSize: number, handler: PcmChunkHandler) {
    this.chunkSize = chunkSize;
    this.handler = handler;
  }

  append(bytes: Uint8Array): void {
    for (let index = 0; index < bytes.length; index++) {
      this.pending.push(bytes[index]);
    }

    while (this.pending.length >= this.chunkSize) {
      const chunk: Uint8Array = new Uint8Array(this.chunkSize);
      for (let index = 0; index < this.chunkSize; index++) {
        chunk[index] = this.pending[index];
      }
      this.pending.splice(0, this.chunkSize);
      this.handler(chunk);
    }
  }

  reset(): void {
    this.pending = [];
  }
}

export interface AudioCaptureSource {
  start(): Promise<void>;
  stop(): Promise<void>;
}

export class MicrophoneCapture implements AudioCaptureSource {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private readonly chunker: PcmChunker;
  private readonly readDataCallback: (buffer: ArrayBuffer) => void;

  constructor(handler: PcmChunkHandler) {
    this.chunker = new PcmChunker(3200, handler);
    this.readDataCallback = (buffer: ArrayBuffer): void => {
      this.chunker.append(new Uint8Array(buffer));
    };
  }

  async start(): Promise<void> {
    try {
      Log.info('Starting microphone with SOURCE_TYPE_LIVE...');
      await this.startWithSource(audio.SourceType.SOURCE_TYPE_LIVE);
      Log.info('Microphone started with SOURCE_TYPE_LIVE');
    } catch (liveSourceError) {
      // SOURCE_TYPE_LIVE enables acoustic echo cancellation on API 20, but
      // support still depends on the phone. Keep microphone translation usable
      // by falling back to the broadly supported recognition source.
      Log.warn(`Live microphone source unavailable: ${JSON.stringify(liveSourceError)}, falling back to VOICE_RECOGNITION...`);
      await this.releaseCurrent();
      try {
        await this.startWithSource(audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION);
        Log.info('Microphone started with SOURCE_TYPE_VOICE_RECOGNITION');
      } catch (fallbackError) {
        await this.releaseCurrent();
        if (fallbackError instanceof Error) {
          throw fallbackError;
        }
        throw new Error(JSON.stringify(fallbackError));
      }
    }
  }

  async stop(): Promise<void> {
    this.chunker.reset();
    await this.releaseCurrent();
  }

  private async startWithSource(source: audio.SourceType): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: source,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };

    this.capturer = await audio.createAudioCapturer(options);
    this.capturer.on('readData', this.readDataCallback);
    await this.capturer.start();
  }

  private async releaseCurrent(): Promise<void> {
    const current: audio.AudioCapturer | undefined = this.capturer;
    this.capturer = undefined;
    if (current === undefined) {
      return;
    }

    try {
      current.off('readData', this.readDataCallback);
      if (current.state === audio.AudioState.STATE_RUNNING ||
        current.state === audio.AudioState.STATE_PAUSED) {
        await current.stop();
      }
    } catch (error) {
      console.warn(`Stopping microphone capture failed: ${JSON.stringify(error)}`);
    }

    try {
      await current.release();
    } catch (error) {
      console.warn(`Releasing microphone capture failed: ${JSON.stringify(error)}`);
    }
  }
}

export class SystemAudioCapture implements AudioCaptureSource {
  private capturer: audio.AudioCapturer | undefined = undefined;
  private readonly chunker: PcmChunker;
  private readonly readDataCallback: (buffer: ArrayBuffer) => void;
  private fallbackNative: boolean = false;
  private pollTimer: number = -1;
  private authorized: boolean = false;

  constructor(handler: PcmChunkHandler) {
    this.chunker = new PcmChunker(3200, handler);
    this.readDataCallback = (buffer: ArrayBuffer): void => {
      this.chunker.append(new Uint8Array(buffer));
    };
  }

  async start(): Promise<void> {
    try {
      Log.info('SystemAudioCapture: Attempting API 26 AudioPlaybackCapture (MODE_MEDIA | MODE_EXCLUDING_SELF)...');
      await this.startApi26PlaybackCapture();
      Log.info('SystemAudioCapture: API 26 AudioPlaybackCapture started successfully!');
    } catch (api26Error) {
      const errMsg: string = api26Error instanceof Error ? api26Error.message : JSON.stringify(api26Error);
      Log.error(`SystemAudioCapture API 26 start failed: ${errMsg}`);
      await this.releaseCapturer();
      throw new Error(`API 26 纯音频内录启动失败：${errMsg}`);
    }
  }

  private async startApi26PlaybackCapture(): Promise<void> {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };

    const capturerInfo: audio.AudioCapturerInfo = {
      source: (audio.SourceType.SOURCE_TYPE_PLAYBACK_CAPTURE ?? 3) as audio.SourceType,
      capturerFlags: 0
    };

    // MODE_MEDIA (0x0001) | MODE_EXCLUDING_SELF (0x8000) = 0x8001
    const playbackMode: number = 0x8001;

    const options: PlaybackCapturerOptions = new PlaybackCapturerOptions();
    options.streamInfo = streamInfo;
    options.capturerInfo = capturerInfo;
    options.playbackCaptureMode = playbackMode;

    this.capturer = await audio.createAudioCapturer(options);
    Log.info('SystemAudioCapture: AudioCapturer instance created for API 26 PlaybackCapture');

    this.capturer.on('readData', this.readDataCallback);

    const controller: PlaybackCaptureController = this.capturer as Object as PlaybackCaptureController;
    if (typeof controller.requestPlaybackCaptureStart === 'function') {
      Log.info('SystemAudioCapture: invoking requestPlaybackCaptureStart()...');
      const state: number = await new Promise<number>((resolve, reject) => {
        try {
          if (controller.requestPlaybackCaptureStart) {
            controller.requestPlaybackCaptureStart((stateCode: number) => {
              Log.info(`SystemAudioCapture: requestPlaybackCaptureStart state=${stateCode}`);
              resolve(stateCode);
            });
          } else {
            resolve(0);
          }
        } catch (e) {
          reject(e);
        }
      });

      Log.info(`SystemAudioCapture: requestPlaybackCaptureStart final state=${state}`);
      if (state === 2) {
        throw new Error('系统内录未获用户授权 (STATE_NOT_AUTHORIZED)');
      } else if (state === 1) {
        throw new Error('系统内录启动失败 (STATE_FAILED)');
      }
    } else {
      Log.warn('SystemAudioCapture: requestPlaybackCaptureStart is not available, falling back to start()');
      await this.capturer.start();
    }

    Log.info('SystemAudioCapture: API 26 PlaybackCapture is running!');
    this.fallbackNative = false;
  }

  private startNativeFallback(): Promise<void> {
    Log.info('SystemAudioCapture: calling startPlaybackCapture() on Native bridge...');
    const requestResult: number = playbackCaptureNative.startPlaybackCapture();
    Log.info(`SystemAudioCapture: Native startPlaybackCapture returned ${requestResult}`);
    if (requestResult !== 0) {
      return Promise.reject(new Error(`系统内录启动失败（错误码：${requestResult}）`));
    }

    this.authorized = false;
    const startedAt: number = Date.now();
    return new Promise<void>((resolve, reject) => {
      this.pollTimer = setInterval(() => {
        const state: number = playbackCaptureNative.getPlaybackCaptureState();
        if (state === 2) {
          if (!this.authorized) {
            this.authorized = true;
            Log.info('SystemAudioCapture: Native authorization granted, capture running!');
            resolve();
          }
          const source: ArrayBuffer = playbackCaptureNative.readPlaybackPcm(19200);
          if (source.byteLength > 0) {
            this.chunker.append(this.downmixAndResample(new Uint8Array(source)));
          }
          return;
        }

        if (state === 3 || state === 4) {
          Log.warn(`SystemAudioCapture: state changed to ${state} (3=NOT_AUTHORIZED, 4=FAILED)`);
          this.clearPollTimer();
          playbackCaptureNative.stopPlaybackCapture();
          reject(new Error(state === 3
            ? '系统内录未获授权，请检查系统设置或切换为“麦克风”模式'
            : '系统内录启动失败或设备不支持'));
          return;
        }

        if (Date.now() - startedAt > 30000) {
          Log.error('SystemAudioCapture: authorization timeout (30s)');
          this.clearPollTimer();
          playbackCaptureNative.stopPlaybackCapture();
          reject(new Error('等待系统内录授权超时'));
        }
      }, 50);
    });
  }

  async stop(): Promise<void> {
    Log.info('SystemAudioCapture: stop() called');
    this.chunker.reset();
    if (this.fallbackNative) {
      this.clearPollTimer();
      this.authorized = false;
      playbackCaptureNative.stopPlaybackCapture();
    } else {
      await this.releaseCapturer();
    }
  }

  private async releaseCapturer(): Promise<void> {
    const current: audio.AudioCapturer | undefined = this.capturer;
    this.capturer = undefined;
    if (current === undefined) {
      return;
    }
    try {
      current.off('readData', this.readDataCallback);
      if (current.state === audio.AudioState.STATE_RUNNING ||
          current.state === audio.AudioState.STATE_PAUSED) {
        await current.stop();
      }
    } catch (error) {
      Log.warn(`Stopping audio playback capturer failed: ${JSON.stringify(error)}`);
    }
    try {
      await current.release();
    } catch (error) {
      Log.warn(`Releasing audio playback capturer failed: ${JSON.stringify(error)}`);
    }
  }

  private clearPollTimer(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private downmixAndResample(source: Uint8Array): Uint8Array {
    const outputSamples: number = Math.floor(source.length / 12);
    const output: Uint8Array = new Uint8Array(outputSamples * 2);
    for (let index = 0; index < outputSamples; index++) {
      const sourceOffset: number = index * 12;
      let sum: number = 0;
      for (let frame = 0; frame < 3; frame++) {
        const frameOffset: number = sourceOffset + frame * 4;
        sum += this.readInt16(source, frameOffset);
        sum += this.readInt16(source, frameOffset + 2);
      }
      const mono: number = Math.round(sum / 6);
      output[index * 2] = mono & 0xFF;
      output[index * 2 + 1] = (mono >> 8) & 0xFF;
    }
    return output;
  }

  private readInt16(source: Uint8Array, offset: number): number {
    let value: number = source[offset] | (source[offset + 1] << 8);
    if ((value & 0x8000) !== 0) {
      value -= 0x10000;
    }
    return value;
  }
}
