// Device model from the user agent, as sent in `hello.device.model`.
export type DeviceModel =
  | 'iPad'
  | 'iPhone'
  | 'iPod touch'
  | 'Android phone'
  | 'Android tablet'
  | 'Windows PC'
  | 'Mac'
  | 'Browser';

export function detectModel(ua: string, maxTouchPoints: number): DeviceModel {
  if (/iPad/.test(ua)) return 'iPad';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPod/.test(ua)) return 'iPod touch';
  if (/Android/.test(ua)) return /Mobile/.test(ua) ? 'Android phone' : 'Android tablet';
  if (/Windows/.test(ua)) return 'Windows PC';
  if (/Macintosh/.test(ua)) return maxTouchPoints > 1 ? 'iPad' : 'Mac';
  return 'Browser';
}

export function currentModel(): DeviceModel {
  const nav = globalThis.navigator;
  return detectModel(nav?.userAgent ?? '', nav?.maxTouchPoints ?? 0);
}

export function isTablet(model: DeviceModel = currentModel()): boolean {
  return model === 'iPad' || model === 'Android tablet';
}

export function deviceKind(model: string): 'smartphone' | 'tablet' | 'monitor' {
  if (/iPad|tablet/i.test(model)) return 'tablet';
  if (/iPhone|iPod|phone/i.test(model)) return 'smartphone';
  return 'monitor';
}
