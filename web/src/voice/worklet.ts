// AudioWorklet that turns microphone input into 16 kHz Int16 blocks.
// Built to /voice-worklet.js. It must not import anything shared with the app
// bundle except the self-contained downsampler.
import { Downsampler } from './downsample';

interface WorkletPort {
  postMessage(msg: unknown, transfer?: Transferable[]): void;
  onmessage: ((ev: { data: unknown }) => void) | null;
}

declare const sampleRate: number;
declare function registerProcessor(name: string, ctor: unknown): void;
declare class AudioWorkletProcessor {
  readonly port: WorkletPort;
}

class RemotoVoiceProcessor extends AudioWorkletProcessor {
  private readonly ds: Downsampler;
  private running = true;

  constructor() {
    super();
    this.ds = new Downsampler(Math.max(16000, sampleRate), (b) => {
      this.port.postMessage({ pcm: b.pcm.buffer, peak: b.peak }, [b.pcm.buffer]);
    });
    this.port.onmessage = (ev) => {
      if (ev.data === 'stop') this.running = false;
    };
  }

  process(inputs: Float32Array[][]): boolean {
    const ch = inputs[0]?.[0];
    if (ch && ch.length) this.ds.push(ch);
    return this.running;
  }
}

registerProcessor('remoto-voice', RemotoVoiceProcessor);
