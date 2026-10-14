/**
 * Carrying a passage from one page to another.
 *
 * Select text in a report or a comment and two things become possible: quoting it in a
 * comment, and citing it in a claim. Both need the passage to survive a navigation,
 * because the place you want to use it is almost never the page you found it on.
 *
 * sessionStorage, not localStorage. A carried quotation is part of one sitting — you found
 * something, you are on your way to say something about it. localStorage would have it
 * still waiting three weeks later, attached to a page nobody remembers reading, and the
 * first thing a stale quote does is get posted by accident.
 *
 * One passage at a time, deliberately. A tray of accumulated quotations is a feature for
 * writing a survey, and this is a feature for making one point.
 */

export type NodeType = 'report' | 'claim';

export interface Passage {
  /** The selected text, normalised and capped. Stored on the citation as the excerpt. */
  readonly text: string;
  readonly sourceType: NodeType;
  readonly sourceId: string;
  readonly sourceTitle: string;
  readonly sourceHref: string;
  /** Set when the selection was inside a comment rather than the page's own text. */
  readonly commentId: string | null;
}

const KEY = 'mathemact:quote';

/** The database caps an excerpt at 2,000 characters. Selecting half a transcript and
 *  discovering afterwards that it was refused is a worse experience than being told now. */
export const EXCERPT_MAX = 2000;

export function getPassage(): Passage | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;

    const parsed = JSON.parse(raw) as Passage;
    // A stored shape from an older deploy is discarded rather than half-used: every field
    // below is one the citation insert would fail without.
    if (!parsed?.text || !parsed.sourceId || !parsed.sourceType) return null;

    return parsed;
  } catch {
    // Private browsing, a full quota, or hand-edited storage. None of them is worth an
    // error where a quotation should be.
    return null;
  }
}

export function setPassage(passage: Passage): void {
  try {
    sessionStorage.setItem(KEY, JSON.stringify(passage));
  } catch {
    /* Nothing to do and nothing worth saying: the quote simply does not travel. */
  }
}

export function clearPassage(): void {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    /* As above. */
  }
}

/** Collapse the whitespace a selection picks up across element boundaries, and cap it. */
export function tidy(text: string): string {
  const collapsed = text.replace(/\s+/g, ' ').trim();
  return collapsed.length > EXCERPT_MAX ? `${collapsed.slice(0, EXCERPT_MAX - 1)}…` : collapsed;
}

/**
 * A passage as markdown, ready to drop into a comment box.
 *
 * A blockquote and an attribution line, and no more than that. The temptation is to add
 * "In [Title], the author wrote:" — but the person quoting is about to say why they are
 * quoting, and prefacing their words with ours makes the comment read as though the site
 * wrote the first sentence.
 */
export function asMarkdown(passage: Passage): string {
  const quoted = passage.text
    .split('\n')
    .map((line) => `> ${line}`)
    .join('\n');

  return `${quoted}\n\n— [${passage.sourceTitle.replace(/[[\]]/g, '')}](${passage.sourceHref})\n\n`;
}

// ── The affordance ────────────────────────────────────────────────────────────────────

export interface AffordanceOptions {
  /** What this page is, so a passage taken from it knows where it came from. */
  readonly nodeType: NodeType;
  readonly nodeId: string;
  readonly title: string;
  readonly href: string;
  /** Where "quote this in a comment" should put the text when the composer is on this
   *  page. Returning false means there is nowhere to put it and the button is not offered. */
  readonly quoteHere: (passage: Passage) => boolean;
  /** Where "cite this in a claim" goes. */
  readonly proposeHref: string;
}

/**
 * Watch for a selection inside anything marked `data-quotable` and offer the two actions.
 *
 * Selection-driven interfaces are usually mouse-only, and this one is not: the popover's
 * buttons are ordinary buttons in the tab order, so extending a selection with
 * shift+arrows and then tabbing reaches them. Escape dismisses. Nothing here animates,
 * which happens to make `prefers-reduced-motion` a non-question rather than a media query.
 */
export function installQuoteAffordance(options: AffordanceOptions): void {
  const popover = document.createElement('div');
  popover.className = 'quote-pop';
  popover.hidden = true;
  popover.setAttribute('role', 'group');
  popover.setAttribute('aria-label', 'Do something with the selected passage');

  const quote = document.createElement('button');
  quote.type = 'button';
  quote.className = 'quote-pop__action';
  quote.textContent = 'Quote in a comment';

  const cite = document.createElement('button');
  cite.type = 'button';
  cite.className = 'quote-pop__action';
  cite.textContent = 'Cite in a claim';

  popover.append(quote, cite);
  document.body.append(popover);

  let current: Passage | null = null;

  function hide(): void {
    popover.hidden = true;
    current = null;
  }

  function capture(): Passage | null {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;

    const text = tidy(selection.toString());
    // Two words is not a quotation, and a stray double-click should not summon a popover
    // over the page every time somebody selects a word to look it up.
    if (text.length < 12) return null;

    const range = selection.getRangeAt(0);
    const anchor =
      range.commonAncestorContainer instanceof Element
        ? range.commonAncestorContainer
        : range.commonAncestorContainer.parentElement;

    if (!anchor?.closest('[data-quotable]')) return null;

    return {
      text,
      sourceType: options.nodeType,
      sourceId: options.nodeId,
      sourceTitle: options.title,
      sourceHref: options.href,
      // A selection inside a comment cites that comment; one in the page's own prose cites
      // the page. The difference is what lets a "referenced by" entry land on a paragraph.
      commentId: anchor.closest<HTMLElement>('[data-comment-id]')?.dataset.commentId ?? null,
    };
  }

  function show(): void {
    const passage = capture();
    if (!passage) {
      hide();
      return;
    }

    current = passage;

    const rect = window.getSelection()!.getRangeAt(0).getBoundingClientRect();
    popover.hidden = false;

    // Placed under the end of the selection, and nudged back inside the viewport rather
    // than clamped to it: a popover half off a phone screen is a popover with one button.
    const left = Math.min(
      Math.max(8, rect.left + window.scrollX),
      window.scrollX + document.documentElement.clientWidth - popover.offsetWidth - 8,
    );

    popover.style.insetInlineStart = `${left}px`;
    popover.style.insetBlockStart = `${rect.bottom + window.scrollY + 8}px`;
  }

  // `selectionchange` rather than mouseup, because it is the one event that fires for a
  // keyboard selection, a touch selection and a mouse drag alike.
  document.addEventListener('selectionchange', () => {
    // A selection inside the popover's own buttons must not re-trigger it.
    if (document.activeElement && popover.contains(document.activeElement)) return;
    show();
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') hide();
  });

  quote.addEventListener('click', () => {
    if (!current) return;

    // Carried *and* inserted here, which looks like doing two things and is one. Quoting a
    // passage into the thread it came from records no citation — a page does not reference
    // itself, and the database refuses one that tries. But the same passage is very often
    // wanted on a different page a minute later, and the composer there offers it with a
    // visible discard. Nothing is attached without being shown first.
    setPassage(current);
    options.quoteHere(current);

    hide();
  });

  cite.addEventListener('click', () => {
    if (!current) return;

    setPassage(current);
    window.location.href = options.proposeHref;
  });
}
