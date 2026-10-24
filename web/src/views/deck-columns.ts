// Columns shown for a deck page: the page's columns scaled by the available
// width (366 px per "phone width") and divided by the button size setting.
export function deckColumns(columns: number, width: number, size: number): number {
  const n = Math.round((columns * Math.max(1, width / 366)) / Math.max(size, 0.1));
  return Math.min(12, Math.max(1, n));
}
