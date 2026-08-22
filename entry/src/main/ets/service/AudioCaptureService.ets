import { audio } from '@kit.AudioKit';
import playbackCaptureNative from 'libentry.so';
import { Log } from '../util/Logger';

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
  private pollTimer: number = -1;
  private authorized: boolean = false;
  private readonly chunker: PcmChunker;

  constructor(handler: PcmChunkHandler) {
    this.chunker = new PcmChunker(3200, handler);
  }

  start(): Promise<void> {
    const requestResult: number = playbackCaptureNative.startPlaybackCapture();
    if (requestResult !== 0) {
      return Promise.reject(new Error(`系统内录启动失败（${requestResult}）`));
    }

    this.authorized = false;
    const startedAt: number = Date.now();
    return new Promise<void>((resolve, reject) => {
      this.pollTimer = setInterval(() => {
        const state: number = playbackCaptureNative.getPlaybackCaptureState();
        if (state === 2) {
          if (!this.authorized) {
            this.authorized = true;
            resolve();
          }
          const source: ArrayBuffer = playbackCaptureNative.readPlaybackPcm(19200);
          if (source.byteLength > 0) {
            this.chunker.append(this.downmixAndResample(new Uint8Array(source)));
          }
          return;
        }

        if (state === 3 || state === 4) {
          this.clearPollTimer();
          playbackCaptureNative.stopPlaybackCapture();
          reject(new Error(state === 3 ? '未获得系统内录授权' : '系统内录不可用'));
          return;
        }

        if (Date.now() - startedAt > 30000) {
          this.clearPollTimer();
          playbackCaptureNative.stopPlaybackCapture();
          reject(new Error('等待系统内录授权超时'));
        }
      }, 20);
    });
  }

  async stop(): Promise<void> {
    this.clearPollTimer();
    this.authorized = false;
    this.chunker.reset();
    playbackCaptureNative.stopPlaybackCapture();
  }

  private clearPollTimer(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private downmixAndResample(source: Uint8Array): Uint8Array {
    // Native capture is PCM16 LE, 48 kHz, stereo. Average each group of three
    // stereo frames into one mono sample. This performs the exact 3:1 rate
    // conversion and adds a small box filter instead of simply dropping frames.
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
