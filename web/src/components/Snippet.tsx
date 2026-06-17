import type { MatchRange } from "../types";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Render a search snippet with its matched terms wrapped in <mark>. The ranges
 * are UTF-8 *byte* offsets (the core works in bytes), so we slice the encoded
 * bytes and decode each segment rather than indexing the UTF-16 JS string.
 */
export function Snippet({ snippet, ranges }: { snippet: string; ranges: MatchRange[] }) {
  if (ranges.length === 0) return <>{snippet}</>;

  const bytes = encoder.encode(snippet);
  const sorted = [...ranges].sort((a, b) => a.start - b.start);
  const parts: { mark: boolean; text: string }[] = [];
  let cursor = 0;

  for (const r of sorted) {
    if (r.start < cursor) continue; // skip overlaps defensively
    if (r.start > cursor) {
      parts.push({ mark: false, text: decoder.decode(bytes.slice(cursor, r.start)) });
    }
    parts.push({ mark: true, text: decoder.decode(bytes.slice(r.start, r.start + r.len)) });
    cursor = r.start + r.len;
  }
  if (cursor < bytes.length) {
    parts.push({ mark: false, text: decoder.decode(bytes.slice(cursor)) });
  }

  return (
    <>
      {parts.map((p, i) => (p.mark ? <mark key={i}>{p.text}</mark> : <span key={i}>{p.text}</span>))}
    </>
  );
}
