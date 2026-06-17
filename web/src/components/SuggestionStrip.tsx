import type { ThoughtMatch } from "../types";

/**
 * Composition-time suggestions: a thin, passive strip of related past thoughts
 * shown while a draft is being written. It never steals focus or blocks typing —
 * it can be dismissed, and the composer keeps the caret throughout.
 */
export function SuggestionStrip({
  suggestions,
  onPick,
  onDismiss,
}: {
  suggestions: ThoughtMatch[];
  onPick: (id: string) => void;
  onDismiss: () => void;
}) {
  if (suggestions.length === 0) return null;
  return (
    <div className="flex items-center gap-3 border-b border-rule bg-surface px-4 py-2">
      <span className="shrink-0 text-[11px] uppercase tracking-wide text-ink-faint">related</span>
      <div className="flex min-w-0 gap-2 overflow-x-auto">
        {suggestions.map((m) => (
          <button
            key={m.thought.id}
            type="button"
            onClick={() => onPick(m.thought.id)}
            title={m.thought.text}
            className="max-w-xs shrink-0 truncate border border-rule-strong px-2 py-0.5 text-ink-muted hover:border-accent hover:text-ink"
          >
            {m.snippet}
          </button>
        ))}
      </div>
      <button
        type="button"
        onClick={onDismiss}
        aria-label="dismiss suggestions"
        className="ml-auto shrink-0 px-1 text-ink-faint hover:text-accent"
      >
        ✕
      </button>
    </div>
  );
}
