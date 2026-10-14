/**
 * Filtering, sorting, and the URL for a corpus listing.
 *
 * One engine behind /reports/, /opinions/ and /network/. It was written for the reports
 * listing and lived inside it; the other two had a sort and no filters, and a category
 * radio group with an Apply button that submitted a GET to a static host and therefore
 * did nothing. Three listings with three interaction models is three things to learn, and
 * the two thin ones were the ones that read as unfinished.
 *
 * **This module must not import anything that reaches src/lib/supabase.ts.** All three
 * listings load it in the browser, and CLAUDE.md's rule is that a reading page never pulls
 * the auth bundle. It imports nothing at all, which is the easiest way to keep that true.
 *
 * The contract with the page is a handful of data attributes, all of them written by
 * `src/components/Listing.astro` except the cards themselves:
 *
 *   [data-filters]     the <form> holding the fieldsets. Absent on an empty corpus.
 *   [data-group=k]     one fieldset per dimension
 *   [data-options]     where that fieldset's <label>s go
 *   [data-more]        the "show all N" button for a long vocabulary
 *   [data-tally=k:v]   the count beside one option
 *   [data-head]        the count-and-sort row, hidden while the corpus is empty
 *   [data-count]       "12 reports" / "3 of 12 reports"
 *   [data-chips]       the removable active filters
 *   [data-clear]       clear everything
 *   [data-dropped]     the notice about filters a link named that nothing has
 *   [data-sort]        the <select>
 *   [data-no-results]  the box shown when nothing matches
 *   [data-suggestion]  the sentence inside it naming the filter to loosen
 *
 * The address bar is the state. Every change writes to it with replaceState and the page
 * reads it on load and on back-navigation, so a filtered view survives being copied,
 * bookmarked, or arrived at from a tag link on a report page. That is the reason the whole
 * corpus is rendered into the page and the filters hide what is already there: a filter
 * that needs a round trip is a filter people stop using, and there is no server to ask.
 *
 * **A listing filters what was posted today as well as what the last export contained.**
 * The three pages are built from a nightly export and then ask the database for anything
 * newer, so on any given afternoon some of what a reader is looking at was never in the
 * build. Those cards go through `add()`, which offers a checkbox for any value the build
 * had no row to justify and then re-runs the whole cycle — so a report posted an hour ago
 * is counted, sorted, tallied and filtered exactly like one from March.
 *
 * This is why the frame is rendered even when the export is empty, and why `ensureGroup()`
 * exists. An empty corpus is the state where *everything* is fresh, and it was the one
 * state with no filters at all: the rail was inside the `length > 0` branch, so the first
 * day the site had content was the one day none of it could be filtered. corpus.css hides a
 * rail with no fieldsets in it and closes the grid up behind it, so an empty page does not
 * show an empty sidebar while it waits.
 */

/** One filterable axis. */
export interface Dimension {
  /** The input name and the URL parameter. */
  readonly key: string;
  /** The fieldset's legend. */
  readonly legend: string;
  /**
   * What a chip calls it, and how the "nothing matches" sentence names it. Defaults to
   * `legend`, and exists for the ones whose legend is a phrase: "Subject area" is right
   * above a list of arXiv categories and wrong inside a chip already showing one.
   */
  readonly chipKind?: string;
  /** The card's `data-*` attribute in dataset form. Defaults to `key`. */
  readonly attr?: string;
  /** Whether the card holds a `|`-separated list rather than a single value. */
  readonly multi?: boolean;
  /**
   * How the ticked values combine within this one dimension.
   *
   * `any` is the right default and is what almost everything uses: "research or teaching"
   * is the useful question, where "research and teaching" would always be empty. `all` is
   * for a dimension whose values are not alternatives — see the `has` dimension on
   * /reports/, where ticking "the prompts" and "code" means both.
   */
  readonly mode?: 'any' | 'all';
}

/** One entry in the sort <select>. `compare` is absent on the default ordering. */
export interface Sort {
  readonly value: string;
  readonly label: string;
  /** Returns 0 to fall through to the newest-first tiebreak. */
  readonly compare?: (a: HTMLElement, b: HTMLElement) => number;
}

export interface ListingOptions {
  /** Every card the filters know about. The freshness overlay adds more through `add()`. */
  readonly cards: HTMLElement[];
  readonly dimensions: readonly Dimension[];
  readonly sorts?: readonly Sort[];
  /** Singular and plural, because "entries" is not "entry" + s. */
  readonly noun: readonly [singular: string, plural: string];
  /**
   * An ordering applied before the chosen sort and never overridden by it.
   *
   * /network/ uses it to keep unreachable entries last. A broken link is a fact in the
   * corpus and is never silently hidden, but it is also not what somebody scanning the
   * list is looking for.
   */
  readonly primary?: (a: HTMLElement, b: HTMLElement) => number;
  /**
   * The human label for a value that arrived on a fresh card and has no checkbox yet.
   * Given the card as well, because /reports/ carries tool display names in an attribute
   * parallel to the lower-cased keys it filters on.
   */
  readonly injectLabel?: (key: string, value: string, card: HTMLElement) => string;
  /**
   * Old URL parameter names, mapped to the dimension that replaced them. /network/
   * filtered on `?cat=` before this engine existed, and a linkable filter that stops being
   * linkable is a broken promise rather than a rename.
   */
  readonly legacyParams?: Readonly<Record<string, string>>;
}

export interface Listing {
  /** Re-run matching, counting, ordering and painting. `pushUrl` writes the address bar. */
  apply(pushUrl?: boolean): void;
  /** Absorb cards the freshness overlay prepended, offering any new filter values. */
  add(cards: HTMLElement[]): void;
}

type Chosen = Record<string, string[]>;

/** Options past this many in one fieldset are folded behind a "show all" button. The
 *  subject-area vocabulary is 32 arXiv categories, and a rail that opens with 32 unread
 *  checkboxes buries every dimension under it. */
const VISIBLE = 8;

/**
 * Wire a listing. Returns null when the page has no filter form, which is the empty
 * corpus — there is nothing to filter and the freshness overlay handles that page itself.
 */
export function createListing(options: ListingOptions): Listing | null {
  const form = document.querySelector<HTMLFormElement>('[data-filters]');
  const resultsEl = document.querySelector<HTMLElement>('[data-results]');
  if (!form || !resultsEl) return null;

  /**
   * The same nodes, aliased so the null checks above survive into everything below.
   *
   * TypeScript keeps a `const` narrowing inside arrow functions but drops it inside hoisted
   * `function` declarations, so every use inside the functions in this file would otherwise
   * be an error while the identical use in an event listener a few lines away is fine. The
   * reports listing had six `!` assertions from working around that one use at a time, and
   * three places where it had not been worked around. Aliasing settles it once.
   */
  const filters = form;
  const results = resultsEl;

  const { cards, dimensions, noun, primary, injectLabel, legacyParams } = options;
  const sorts = options.sorts ?? [];

  const head = document.querySelector<HTMLElement>('[data-head]');
  const count = document.querySelector<HTMLElement>('[data-count]');
  const chips = document.querySelector<HTMLElement>('[data-chips]');
  const noResults = document.querySelector<HTMLElement>('[data-no-results]');
  const suggestion = document.querySelector<HTMLElement>('[data-suggestion]');
  const dropped = document.querySelector<HTMLElement>('[data-dropped]');
  const sort = document.querySelector<HTMLSelectElement>('[data-sort]');
  const toggle = document.querySelector<HTMLButtonElement>('[data-filters-toggle]');
  const activeCount = document.querySelector<HTMLElement>('[data-active-count]');

  const attrOf = (d: Dimension) => d.attr ?? d.key;
  const chipKindOf = (d: Dimension) => d.chipKind ?? d.legend;

  // ── Matching ────────────────────────────────────────────────────────────────────────

  function selected(): Chosen {
    const chosen: Chosen = {};

    for (const dimension of dimensions) {
      chosen[dimension.key] = [
        ...filters.querySelectorAll<HTMLInputElement>(
          `input[name="${dimension.key}"]:checked`,
        ),
      ].map((input) => input.value);
    }

    return chosen;
  }

  /** Whether one card satisfies one dimension. An empty selection matches everything. */
  function matchesDimension(card: HTMLElement, dimension: Dimension, values: string[]): boolean {
    if (values.length === 0) return true;

    const raw = card.dataset[attrOf(dimension)] ?? '';

    // Dimensions are always AND'd with each other. Within a dimension it is OR unless the
    // dimension says otherwise — see `mode` on Dimension.
    if (!dimension.multi) return values.includes(raw);

    const held = raw.split('|').filter(Boolean);
    return dimension.mode === 'all'
      ? values.every((value) => held.includes(value))
      : held.some((entry) => values.includes(entry));
  }

  function matches(card: HTMLElement, chosen: Chosen): boolean {
    return dimensions.every((dimension) =>
      matchesDimension(card, dimension, chosen[dimension.key] ?? []),
    );
  }

  // ── Ordering ────────────────────────────────────────────────────────────────────────

  /** Newest first, and the tiebreak under every other ordering. The dates are ISO, so the
   *  lexicographic comparison is the chronological one. */
  function newestFirst(a: HTMLElement, b: HTMLElement): number {
    return (b.dataset.created ?? '').localeCompare(a.dataset.created ?? '');
  }

  function order(): void {
    const chosen = sorts.find((entry) => entry.value === sort?.value);

    const sorted = [...cards].sort(
      (a, b) =>
        (primary?.(a, b) ?? 0) || (chosen?.compare?.(a, b) ?? 0) || newestFirst(a, b),
    );

    for (const card of sorted) results.append(card);
  }

  // ── Painting ────────────────────────────────────────────────────────────────────────

  function plural(n: number): string {
    return n === 1 ? noun[0] : noun[1];
  }

  function paintCount(visible: number): void {
    if (!count) return;

    count.textContent =
      visible === cards.length
        ? `${cards.length} ${plural(cards.length)}`
        : `${visible} of ${cards.length} ${plural(cards.length)}`;
  }

  function paintChips(chosen: Chosen): void {
    if (!chips) return;
    chips.replaceChildren();

    let any = false;

    for (const dimension of dimensions) {
      for (const value of chosen[dimension.key] ?? []) {
        any = true;

        const input = filters.querySelector<HTMLInputElement>(
          `input[name="${dimension.key}"][value="${CSS.escape(value)}"]`,
        );
        const label = input?.closest('.filters__option')?.querySelector('.filters__label')
          ?.textContent ?? value;

        const chip = document.createElement('li');
        chip.className = 'chip';

        const kind = document.createElement('span');
        kind.className = 'chip__kind';
        kind.textContent = chipKindOf(dimension);

        const text = document.createElement('span');
        text.textContent = label;

        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'chip__remove';
        remove.textContent = '×';
        remove.setAttribute(
          'aria-label',
          `Remove the ${chipKindOf(dimension).toLowerCase()} filter ${label}`,
        );
        remove.addEventListener('click', () => {
          if (input) input.checked = false;
          apply(true);
        });

        chip.append(kind, text, remove);
        chips.append(chip);
      }
    }

    // At the end of the row rather than in the rail. It belongs beside the thing it
    // undoes, and it is the only control here that is absent until there is something for
    // it to do — a permanent "clear all" over an unfiltered listing is a dead control.
    if (any) {
      const item = document.createElement('li');
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'chips__clear';
      button.textContent = 'Clear all';
      button.addEventListener('click', clearAll);
      item.append(button);
      chips.append(item);
    }
  }

  /**
   * How many cards each option would leave, given everything else already chosen.
   *
   * An option that would return nothing is disabled rather than hidden, so the shape of the
   * corpus stays visible: "no report in this corpus is about formalisation" is worth
   * knowing, and a vanishing checkbox says it by saying nothing.
   */
  function paintTallies(chosen: Chosen): void {
    for (const dimension of dimensions) {
      for (const input of filters.querySelectorAll<HTMLInputElement>(
        `input[name="${dimension.key}"]`,
      )) {
        const probe = { ...chosen, [dimension.key]: [input.value] };
        const total = cards.filter((card) => matches(card, probe)).length;

        const tally = filters.querySelector<HTMLElement>(
          `[data-tally="${dimension.key}:${CSS.escape(input.value)}"]`,
        );
        if (tally) tally.textContent = String(total);

        input.disabled = total === 0 && !input.checked;
      }
    }
  }

  function paintActiveCount(chosen: Chosen): void {
    if (!activeCount) return;

    const n = dimensions.reduce((sum, d) => sum + (chosen[d.key]?.length ?? 0), 0);
    activeCount.textContent = n === 0 ? '' : `${n} selected`;
  }

  /**
   * Which single filter to loosen.
   *
   * For each active dimension, count what dropping it alone would return, and name the one
   * that unlocks the most. A dead end with a way out of it is a different thing from a dead
   * end, and "no results" without one is where people leave.
   */
  function suggest(chosen: Chosen): string {
    let best: { dimension: Dimension; gain: number } | null = null;

    for (const dimension of dimensions) {
      if ((chosen[dimension.key] ?? []).length === 0) continue;

      const relaxed = { ...chosen, [dimension.key]: [] as string[] };
      const gain = cards.filter((card) => matches(card, relaxed)).length;

      if (gain > 0 && (!best || gain > best.gain)) best = { dimension, gain };
    }

    if (!best) {
      return 'Clearing the filters brings back the whole corpus, which is the only thing left to try.';
    }

    return (
      `Removing the ${chipKindOf(best.dimension).toLowerCase()} filter would show ` +
      `${best.gain} ${plural(best.gain)}. It is the one narrowing this most.`
    );
  }

  // ── The address bar ─────────────────────────────────────────────────────────────────

  function writeUrl(chosen: Chosen): void {
    const params = new URLSearchParams();

    for (const dimension of dimensions) {
      const values = chosen[dimension.key] ?? [];
      if (values.length) params.set(dimension.key, values.join(','));
    }
    if (sort && sort.value !== sort.options[0]?.value) params.set('sort', sort.value);

    const query = params.toString();
    window.history.replaceState(
      {},
      '',
      query ? `${window.location.pathname}?${query}` : window.location.pathname,
    );
  }

  function readUrl(): void {
    const params = new URLSearchParams(window.location.search);
    const missing: string[] = [];

    for (const dimension of dimensions) {
      const legacy = Object.entries(legacyParams ?? {})
        .filter(([, key]) => key === dimension.key)
        .map(([old]) => params.get(old) ?? '');

      const values = [params.get(dimension.key) ?? '', ...legacy]
        .join(',')
        .split(',')
        .filter(Boolean);

      const offered = new Set<string>();

      for (const input of filters.querySelectorAll<HTMLInputElement>(
        `input[name="${dimension.key}"]`,
      )) {
        offered.add(input.value);
        input.checked = values.includes(input.value);
      }

      for (const value of values) {
        if (!offered.has(value)) missing.push(`${chipKindOf(dimension).toLowerCase()} ${value}`);
      }
    }

    // Said out loud rather than swallowed. Somebody following a link deserves to know that
    // they are seeing a wider view than the person who sent it.
    if (dropped) {
      dropped.hidden = missing.length === 0;
      dropped.textContent = missing.length
        ? `This link also filtered on ${missing.join(', ')}, which nothing in the corpus ` +
          `currently has. Those filters are not applied, so you are seeing more than the ` +
          `person who sent it.`
        : '';
    }

    // Checked against the options the page actually offers, so a stale link naming a sort
    // that has since gone falls back to the first one rather than to an empty select.
    const wanted = params.get('sort');
    if (sort && wanted && [...sort.options].some((option) => option.value === wanted)) {
      sort.value = wanted;
    }
  }

  // ── Long vocabularies ───────────────────────────────────────────────────────────────

  /**
   * Fold everything past the eighth option behind a button, per fieldset.
   *
   * `hidden` rather than a CSS `nth-child` rule, because the freshness overlay appends
   * options at runtime and a rule counting positions would silently start hiding the wrong
   * ones. It works because of the `[hidden]` rule in base.css — without it, the
   * `display: grid` on `.filters__option` would outrank the browser's own.
   */
  function clip(): void {
    for (const dimension of dimensions) {
      const group = filters.querySelector<HTMLElement>(`[data-group="${dimension.key}"]`);
      const more = group?.querySelector<HTMLButtonElement>('[data-more]');
      if (!group || !more) continue;

      const labels = [...group.querySelectorAll<HTMLElement>('.filters__option')];
      const expanded = group.dataset.expanded === 'true';

      // A link can arrive with a value ticked that sits past the fold. Opening the group is
      // the only way the reader can see what is filtering their results, let alone undo it.
      const checkedBeyond = labels
        .slice(VISIBLE)
        .some((label) => label.querySelector<HTMLInputElement>('input')?.checked);

      const open = expanded || checkedBeyond;

      for (const [index, label] of labels.entries()) {
        label.hidden = !open && index >= VISIBLE;
      }

      more.hidden = labels.length <= VISIBLE;
      more.textContent = open
        ? 'Show fewer'
        : `Show all ${labels.length} ${chipKindOf(dimension).toLowerCase()} options`;
      if (open) group.dataset.expanded = 'true';
    }
  }

  // ── Fresh cards ─────────────────────────────────────────────────────────────────────

  /** The fieldset for `dimension`, created if a fresh card is the first thing to use it. */
  function ensureGroup(dimension: Dimension): HTMLElement {
    const existing = filters.querySelector<HTMLElement>(`[data-group="${dimension.key}"]`);
    if (existing) return existing;

    const fieldset = document.createElement('fieldset');
    fieldset.className = 'filters__group';
    fieldset.dataset.group = dimension.key;

    const legend = document.createElement('legend');
    legend.className = 'filters__legend';
    legend.textContent = dimension.legend;

    const list = document.createElement('div');
    list.className = 'filters__options';
    list.dataset.options = '';

    const more = document.createElement('button');
    more.type = 'button';
    more.className = 'filters__more';
    more.dataset.more = '';
    more.hidden = true;
    more.addEventListener('click', () => expand(fieldset));

    fieldset.append(legend, list, more);
    (filters.querySelector('[data-filters-body]') ?? filters).append(fieldset);
    return fieldset;
  }

  function expand(group: HTMLElement): void {
    group.dataset.expanded = group.dataset.expanded === 'true' ? 'false' : 'true';
    clip();
  }

  /** Add one option, if nothing with that dimension and value is offered already. */
  function injectOption(dimension: Dimension, value: string, label: string): void {
    if (!value) return;
    if (
      filters.querySelector(
        `input[name="${dimension.key}"][value="${CSS.escape(value)}"]`,
      )
    ) {
      return;
    }

    const group = ensureGroup(dimension);
    const list = group.querySelector<HTMLElement>('[data-options]');
    if (!list) return;

    const option = document.createElement('label');
    option.className = 'filters__option';

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.name = dimension.key;
    input.value = value;

    const text = document.createElement('span');
    text.className = 'filters__label';
    text.textContent = label;

    const tally = document.createElement('span');
    tally.className = 'filters__tally';
    tally.dataset.tally = `${dimension.key}:${value}`;

    option.append(input, text, tally);
    list.append(option);
  }

  function add(added: HTMLElement[]): void {
    for (const card of added) {
      for (const dimension of dimensions) {
        const raw = card.dataset[attrOf(dimension)] ?? '';
        const values = dimension.multi ? raw.split('|').filter(Boolean) : [raw];

        for (const value of values) {
          injectOption(dimension, value, injectLabel?.(dimension.key, value, card) ?? value);
        }
      }
    }

    cards.push(...added);

    /**
     * Read the address bar again, now that the options exist.
     *
     * `readUrl()` ran at init against the checkboxes the build had rendered, so a link
     * filtering on a value only *today's* content carries — `/opinions/?area=outreach` when
     * the one outreach claim was posted this morning — found no checkbox, unticked
     * nothing, and told the reader "nothing in the corpus currently has this". Both halves
     * were wrong: the filter was silently lost, and the notice said the opposite of the
     * truth. On an empty corpus that is *every* link into the listing.
     *
     * Safe to run unconditionally. Either the reader has not touched the rail, in which
     * case the URL is still the link they followed and this applies the rest of it; or they
     * have, in which case `apply(true)` already wrote their state to the URL and reading it
     * back is a no-op that also clears a notice which no longer applies.
     */
    readUrl();
    apply(false);
  }

  // ── The cycle ───────────────────────────────────────────────────────────────────────

  function apply(pushUrl = false): void {
    const chosen = selected();
    const visible = new Set(cards.filter((card) => matches(card, chosen)));

    for (const card of cards) card.hidden = !visible.has(card);

    paintCount(visible.size);
    order();
    paintChips(chosen);
    paintTallies(chosen);
    paintActiveCount(chosen);
    clip();

    // `|| cards.length === 0` because an empty corpus is not a failed search. Without it
    // the page would answer "nothing matches all of those filters" on the day the site
    // launches, with no filters set and nothing to have matched.
    if (noResults) noResults.hidden = visible.size > 0 || cards.length === 0;
    if (suggestion && visible.size > 0) suggestion.textContent = '';
    else if (suggestion && cards.length > 0) suggestion.textContent = suggest(chosen);

    // Nothing to count and nothing to order. The head reappears the moment the freshness
    // overlay finds a row, which on an empty corpus is the whole of the listing.
    if (head) head.hidden = cards.length === 0;

    if (pushUrl) writeUrl(chosen);
  }

  function clearAll(): void {
    filters.reset();
    // reset() restores the markup's defaults, which is "nothing checked" — but it does not
    // touch `disabled`, and a disabled input stays disabled through it. apply() repaints
    // the tallies, which is where that gets undone.
    apply(true);
  }

  // ── Wiring ──────────────────────────────────────────────────────────────────────────

  filters.addEventListener('change', () => apply(true));
  sort?.addEventListener('change', () => apply(true));

  for (const button of filters.querySelectorAll<HTMLButtonElement>('[data-more]')) {
    const group = button.closest<HTMLElement>('[data-group]');
    if (group) button.addEventListener('click', () => expand(group));
  }

  for (const button of document.querySelectorAll<HTMLButtonElement>('[data-clear]')) {
    button.addEventListener('click', clearAll);
  }

  // Back and forward should move between filtered views, not out of the page.
  window.addEventListener('popstate', () => {
    readUrl();
    apply(false);
  });

  /**
   * The rail collapses on a phone and is a plain sidebar above the grid's breakpoint.
   *
   * A button and two attributes rather than `<details>`, and the reason is the wide case:
   * `<details>` hides its own content through the UA stylesheet in a way an author rule
   * cannot reliably reach, so a panel collapsed on a narrow screen and then widened would
   * leave a summary that corpus.css has hidden and no way to get the filters back.
   *
   * `data-collapsible` is set here rather than in the markup so that the collapse only
   * exists once something is listening for the click. Without it corpus.css leaves the rail
   * open and hides the button, which is the right shape for a page whose script never ran:
   * a control that does nothing is worse than no control, and this file has already paid
   * for that lesson once with `Field.astro`'s counter.
   */
  if (toggle) {
    filters.dataset.collapsible = 'true';
    filters.dataset.open = 'false';

    toggle.addEventListener('click', () => {
      const open = filters.dataset.open !== 'true';
      filters.dataset.open = String(open);
      toggle.setAttribute('aria-expanded', String(open));
    });
  }

  readUrl();
  apply(false);

  return { apply, add };
}
