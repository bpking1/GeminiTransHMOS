import { audio } from '@kit.AudioKit';

export class PcmAudioPlayer {
  private renderer: audio.AudioRenderer | undefined = undefined;
  private queue: Uint8Array[] = [];
  private headOffset: number = 0;
  private availableBytes: number = 0;
  private readonly writeDataCallback: audio.AudioRendererWriteDataCallback;

  constructor() {
    this.writeDataCallback = (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
      const target: Uint8Array = new Uint8Array(buffer);
      if (this.availableBytes < target.length) {
        return audio.AudioDataCallbackResult.INVALID;
      }

      let targetOffset: number = 0;
      while (targetOffset < target.length && this.queue.length > 0) {
        const head: Uint8Array = this.queue[0];
        const copyLength: number = Math.min(
          head.length - this.headOffset, target.length - targetOffset);
        target.set(head.subarray(this.headOffset, this.headOffset + copyLength), targetOffset);
        targetOffset += copyLength;
        this.headOffset += copyLength;
        this.availableBytes -= copyLength;
        if (this.headOffset >= head.length) {
          this.queue.shift();
          this.headOffset = 0;
        }
      }
      return audio.AudioDataCallbackResult.VALID;
    };
  }

  async start(volume: number): Promise<void> {
    if (this.renderer !== undefined) {
      try {
        await this.renderer.setVolume(Math.max(0, Math.min(1, volume)));
        if (this.renderer.state === audio.AudioState.STATE_PAUSED ||
            this.renderer.state === audio.AudioState.STATE_PREPARED) {
          await this.renderer.start();
        }
      } catch (e) {
        console.warn(`PcmAudioPlayer setVolume/start error: ${JSON.stringify(e)}`);
      }
      return;
    }

    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    // STREAM_USAGE_VOICE_ASSISTANT / STREAM_USAGE_MEDIA supports concurrent playback alongside video
    const rendererInfo: audio.AudioRendererInfo = {
      usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT ?? audio.StreamUsage.STREAM_USAGE_MEDIA,
      rendererFlags: 0
    };
    const options: audio.AudioRendererOptions = {
      streamInfo: streamInfo,
      rendererInfo: rendererInfo
    };

    this.renderer = await audio.createAudioRenderer(options);
    this.renderer.on('writeData', this.writeDataCallback);
    this.renderer.on('audioInterrupt', (event: audio.InterruptEvent) => {
      console.info(`[PcmAudioPlayer] audioInterrupt: hintType=${event.hintType}, forceType=${event.forceType}`);
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
        if (this.renderer && (this.renderer.state === audio.AudioState.STATE_PAUSED ||
            this.renderer.state === audio.AudioState.STATE_PREPARED)) {
          this.renderer.start().catch((e: Error) => {
            console.warn(`[PcmAudioPlayer] resume error: ${JSON.stringify(e)}`);
          });
        }
      }
    });

    await this.renderer.setVolume(Math.max(0, Math.min(1, volume)));
    await this.renderer.start();
    console.info('[PcmAudioPlayer] AudioRenderer started successfully with VOICE_ASSISTANT concurrency');
  }

  enqueue(data: Uint8Array): void {
    if (data.length === 0 || this.renderer === undefined) {
      return;
    }

    // Auto-resume if renderer was paused by audio focus transition
    if (this.renderer.state === audio.AudioState.STATE_PAUSED ||
        this.renderer.state === audio.AudioState.STATE_PREPARED) {
      this.renderer.start().catch((e: Error) => {
        console.warn(`[PcmAudioPlayer] auto-resume on enqueue error: ${JSON.stringify(e)}`);
      });
    }

    this.queue.push(data);
    this.availableBytes += data.length;

    // Bound latency if the network suddenly delivers a large audio burst.
    const maximumBytes: number = 24000 * 2 * 4;
    while (this.availableBytes > maximumBytes && this.queue.length > 1) {
      const removed: Uint8Array | undefined = this.queue.shift();
      if (removed !== undefined) {
        this.availableBytes -= removed.length - this.headOffset;
      }
      this.headOffset = 0;
    }
  }

  clear(): void {
    this.queue = [];
    this.headOffset = 0;
    this.availableBytes = 0;
  }

  async stop(): Promise<void> {
    const current: audio.AudioRenderer | undefined = this.renderer;
    this.renderer = undefined;
    this.clear();
    if (current === undefined) {
      return;
    }

    try {
      current.off('writeData', this.writeDataCallback);
      if (current.state === audio.AudioState.STATE_RUNNING ||
        current.state === audio.AudioState.STATE_PAUSED) {
        await current.stop();
      }
    } catch (error) {
      console.warn(`Stopping PCM renderer failed: ${JSON.stringify(error)}`);
    }

    try {
      await current.release();
    } catch (error) {
      console.warn(`Releasing PCM renderer failed: ${JSON.stringify(error)}`);
    }
  }
}

