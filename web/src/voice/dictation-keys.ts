// Message keys for dictation errors (kept apart so tests can import them).
import type { MessageKey } from '../i18n';

export type DictationError =
  | 'voice.err.offline'
  | 'voice.err.unavailable'
  | 'voice.err.insecure'
  | 'voice.err.noAudio'
  | 'voice.err.denied'
  | 'voice.err.stopped';

export const DICTATION_ERROR_KEYS: readonly (DictationError & MessageKey)[] = [
  'voice.err.offline',
  'voice.err.unavailable',
  'voice.err.insecure',
  'voice.err.noAudio',
  'voice.err.denied',
  'voice.err.stopped',
];
