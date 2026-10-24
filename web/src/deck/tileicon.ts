// What a tile shows: explicit icon or an automatic one from its action.
import type { App } from '../app';
import type { Action, Tile } from '../protocol/types';
import { h } from '../ui/dom';
import { icon } from '../ui/icons';
import { appIcon } from '../ui/appicon';

const MEDIA_SYMBOL: Record<string, string> = {
  volumeUp: 'volume-2',
  volumeDown: 'volume-1',
  mute: 'volume-x',
  brightnessUp: 'sun',
  brightnessDown: 'sun-dim',
  playPause: 'play',
  next: 'skip-forward',
  previous: 'skip-back',
  fastForward: 'fast-forward',
  rewind: 'rewind',
  illuminationUp: 'lightbulb',
  illuminationDown: 'lightbulb',
  illuminationToggle: 'lightbulb',
};

const SYSTEM_SYMBOL: Record<string, string> = {
  missionControl: 'layout-grid',
  appExpose: 'app-window',
  showDesktop: 'monitor',
  launchpad: 'rocket',
  spotlight: 'search',
  spaceLeft: 'arrow-left-to-line',
  spaceRight: 'arrow-right-to-line',
  lockScreen: 'lock',
  sleepDisplay: 'monitor-off',
  sleep: 'moon',
  screenshot: 'camera',
  screenshotArea: 'scan',
  screenshotTool: 'camera',
  emojiPicker: 'smile',
  undo: 'undo',
  redo: 'redo',
  copy: 'copy',
  cut: 'scissors',
  paste: 'clipboard',
  find: 'search',
  reload: 'refresh-cw',
  zoomIn: 'zoom-in',
  zoomOut: 'zoom-out',
  fullscreen: 'maximize',
  minimize: 'minimize',
  forceQuit: 'power',
  back: 'chevron-left',
  forward: 'chevron-right',
};

export function symbolFor(a: Action): string {
  switch (a.kind) {
    case 'keys':
      return 'keyboard';
    case 'text':
      return 'type';
    case 'media':
      return MEDIA_SYMBOL[a.key] ?? 'music';
    case 'app':
      return 'app-window';
    case 'url':
      return 'globe';
    case 'system':
      return SYSTEM_SYMBOL[a.name] ?? 'command';
    case 'shortcut':
      return 'layers';
    case 'shell':
      return 'terminal';
    case 'mouse':
      return 'mouse-pointer-click';
    case 'delay':
      return 'timer';
    case 'sequence':
      return 'list-music';
  }
}

export function tileVisual(app: App, tile: Tile): HTMLElement {
  const i = tile.icon;
  if (i?.kind === 'emoji') return h('span', { class: 'tile-emoji', text: i.text, attrs: { 'aria-hidden': 'true' } });
  if (i?.kind === 'app' || (!i && tile.action.kind === 'app')) {
    const id = i?.kind === 'app' ? i.id : tile.action.kind === 'app' ? tile.action.id : '';
    const img = appIcon(app, id, 96);
    img.classList.add('tile-app-img');
    return img;
  }
  const name = i?.kind === 'symbol' ? i.name : symbolFor(tile.action);
  return h('span', { class: 'tile-icon' }, icon(name, 24));
}
