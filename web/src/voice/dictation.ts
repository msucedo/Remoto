// Microphone capture for dictation: getUserMedia -> AudioWorklet (16 kHz Int16)
// -> binary 0x10 frames. Recognition happens on the Mac.
import { out } from '../protocol/codec';
import type { App } from '../app';
import type { DictationError } from './dictation-keys';

export interface DictationEvents {
  state(active: boolean): void;
  level(peak: number): void;
  partial(text: string): void;
  final(text: string): void;
  error(key: DictationError | null, message?: string): void;
}

const WORKLET_URL = import.meta.env.DEV ? '/src/voice/worklet.ts' : '/voice-worklet.js';

export function dictationSupported(app: App): boolean {
  return app.features.voice && app.secureContext && typeof AudioWorkletNode !== 'undefined' && !!navigator.mediaDevices?.getUserMedia;
}

export class Dictation {
  private ctx: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private node: AudioWorkletNode | null = null;
  private active = false;
  private starting = false;
  private readonly unsub: (() => void)[] = [];

  constructor(
    private readonly app: App,
    private readonly ev: DictationEvents,
  ) {
    this.unsub.push(
      app.events.on('voice', (m) => {
        if (!this.active) return;
        if (m.state === 'listening') {
          if (m.final && m.text) {
            this.ev.final(m.text);
            this.ev.partial('');
          } else if (m.text !== undefined) {
            this.ev.partial(m.text);
          }
        } else if (m.state === 'stopped') {
          if (m.text) this.ev.final(m.text);
          this.ev.partial('');
          this.teardown();
        } else {
          this.fail(m.state === 'unavailable' ? 'voice.err.unavailable' : 'voice.err.stopped', m.message);
        }
      }),
      app.events.on('status', (s) => {
        if (s.state !== 'connected' && (this.active || this.starting)) {
          this.teardown();
          this.ev.error('voice.err.offline');
        }
      }),
      app.events.on('suspend', () => this.stop(false)),
    );
  }

  get isActive(): boolean {
    return this.active || this.starting;
  }

  async toggle(): Promise<void> {
    if (this.isActive) this.stop(false);
    else await this.start();
  }

  async start(): Promise<void> {
    if (this.isActive) return;
    const app = this.app;
    const missing: DictationError | null = !app.connected
      ? 'voice.err.offline'
      : !app.features.voice
        ? 'voice.err.unavailable'
        : !app.secureContext
          ? 'voice.err.insecure'
          : typeof AudioWorkletNode === 'undefined' || !navigator.mediaDevices?.getUserMedia
            ? 'voice.err.noAudio'
            : null;
    if (missing) {
      this.ev.error(missing);
      return;
    }
    this.starting = true;
    this.ev.error(null);
    this.ev.state(true);
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });
    } catch (err) {
      this.starting = false;
      this.ev.state(false);
      const name = err instanceof DOMException ? err.name : '';
      this.ev.error(name === 'NotAllowedError' || name === 'SecurityError' ? 'voice.err.denied' : 'voice.err.noAudio');
      return;
    }
    try {
      const ctx = new AudioContext();
      this.ctx = ctx;
      await ctx.audioWorklet.addModule(WORKLET_URL);
      const src = ctx.createMediaStreamSource(this.stream);
      const node = new AudioWorkletNode(ctx, 'remoto-voice', { numberOfInputs: 1, numberOfOutputs: 1, channelCount: 1 });
      this.node = node;
      node.port.onmessage = (e: MessageEvent<{ pcm: ArrayBuffer; peak: number }>) => {
        if (!this.active) return;
        this.app.conn.audio(new Int16Array(e.data.pcm));
        this.ev.level(e.data.peak);
      };
      const mute = ctx.createGain();
      mute.gain.value = 0;
      src.connect(node);
      node.connect(mute);
      mute.connect(ctx.destination);
      if (ctx.state === 'suspended') await ctx.resume();
    } catch {
      this.teardown();
      this.ev.error('voice.err.noAudio');
      return;
    }
    if (!this.starting) {
      // Stopped while setting up.
      this.teardown();
      return;
    }
    this.starting = false;
    this.active = true;
    this.app.send(out.voiceStart(navigator.language));
  }

  stop(cancel: boolean): void {
    if (!this.isActive) return;
    if (this.active) this.app.send(out.voiceStop(cancel));
    this.teardown();
  }

  dispose(): void {
    this.stop(false);
    for (const fn of this.unsub) fn();
  }

  private fail(key: DictationError, message?: string): void {
    this.app.send(out.voiceStop(true));
    this.teardown();
    this.ev.error(key, message);
  }

  private teardown(): void {
    this.active = false;
    this.starting = false;
    try {
      this.node?.port.postMessage('stop');
      this.node?.disconnect();
    } catch {
      // ignore
    }
    this.node = null;
    for (const tr of this.stream?.getTracks() ?? []) tr.stop();
    this.stream = null;
    void this.ctx?.close().catch(() => undefined);
    this.ctx = null;
    this.ev.level(0);
    this.ev.state(false);
  }
}

