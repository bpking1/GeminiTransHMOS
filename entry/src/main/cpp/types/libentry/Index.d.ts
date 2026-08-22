interface PlaybackCaptureNative {
  startPlaybackCapture(): number;
  getPlaybackCaptureState(): number;
  readPlaybackPcm(maxBytes: number): ArrayBuffer;
  stopPlaybackCapture(): number;
}

declare const playbackCaptureNative: PlaybackCaptureNative;
export default playbackCaptureNative;

