// Grapheme handling for live typing: the Mac deletes one Backspace per unit,
// and one Backspace removes one user-perceived character.

type SegmenterCtor = new (locale?: string, opts?: { granularity: 'grapheme' }) => {
  segment(s: string): Iterable<{ segment: string }>;
};

const SegmenterImpl: SegmenterCtor | undefined = (Intl as unknown as { Segmenter?: SegmenterCtor }).Segmenter;
const segmenter = SegmenterImpl ? new SegmenterImpl(undefined, { granularity: 'grapheme' }) : null;

/** Splits a string into grapheme clusters (code points as a fallback). */
export function graphemes(s: string): string[] {
  if (!s) return [];
  if (segmenter) return Array.from(segmenter.segment(s), (x) => x.segment);
  return Array.from(s);
}

export function graphemeCount(s: string): number {
  return graphemes(s).length;
}

export interface EditOp {
  delete: number;
  insert: string;
}

/**
 * Edit that turns `prev` into `next`: keep the common grapheme prefix, delete
 * the rest of `prev` and insert the rest of `next`. Null when nothing changes.
 */
export function diffGraphemes(prev: string, next: string): EditOp | null {
  if (prev === next) return null;
  const a = graphemes(prev);
  const b = graphemes(next);
  let i = 0;
  while (i < a.length && i < b.length && a[i] === b[i]) i++;
  const del = a.length - i;
  const insert = b.slice(i).join('');
  if (del === 0 && !insert) return null;
  return { delete: del, insert };
}

export const LIVE_FIELD_MAX_GRAPHEMES = 2000;

/** Appends dictated text, adding a space when the previous text needs one. */
export function appendWithSpace(current: string, addition: string): string {
  const add = addition.trim();
  if (!add) return current;
  if (!current || /\s$/.test(current)) return current + add;
  return `${current} ${add}`;
}
