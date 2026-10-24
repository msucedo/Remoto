// Resolves the "auto" keyboard mode: Mac keyboard on tablets or wide screens.
export type KeyboardMode = 'mac' | 'custom' | 'phone';

export function resolveKeyboardMode(setting: 'auto' | KeyboardMode, tablet: boolean, width: number): KeyboardMode {
  if (setting !== 'auto') return setting;
  return tablet || width >= 560 ? 'mac' : 'phone';
}
