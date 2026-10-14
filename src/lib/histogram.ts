/**
 * Filling in the histogram.
 *
 * Kept out of the page so that the bars and the screen-reader table are written once, from
 * one set of numbers. Two implementations of "what does this column say" is how a chart and
 * its accessible equivalent end up disagreeing, and the one that ends up wrong is always the
 * one nobody looks at.
 *
 * Bar heights are a proportion of the tallest column, not of the total. A distribution where
 * the largest group is nine people out of forty would otherwise be a row of stubs, and the
 * shape — which is the entire point of showing a histogram rather than a number — would be
 * invisible.
 */
import { NO_OPINION_LABEL, SCALE_ANCHORS, SCALE_POINTS } from './claims';
import type { Aggregate } from './claims';

/**
 * The two figures that do not come from the aggregate.
 *
 * `NaN` means "the export has never seen this claim", which is the state of every claim on
 * /opinions/view/ and of one posted since the last build. Both are then omitted from the line
 * rather than printed as zero — nobody counted them, and a zero would say somebody had.
 */
export interface StaticCounts {
  readonly contributions: number;
  readonly positionChanges: number;
}

export function renderHistogram(
  root: HTMLElement,
  aggregate: Aggregate,
  myScore: number | null,
  iRated: boolean,
  counts?: StaticCounts,
): void {
  const tallest = Math.max(1, ...aggregate.histogram);

  for (const point of SCALE_POINTS) {
    const column = root.querySelector<HTMLElement>(`[data-col="${point}"]`);
    if (!column) continue;

    const count = aggregate.histogram[point] ?? 0;
    const mine = iRated && myScore === point;
    const isMedian = aggregate.median === point;

    column.querySelector<HTMLElement>('[data-count]')!.textContent = String(count);
    column
      .querySelector<HTMLElement>('[data-bar]')!
      .style.setProperty('--height', `${Math.round((count / tallest) * 100)}%`);

    column.toggleAttribute('data-mine', mine);
    column.querySelector<HTMLElement>('[data-you]')!.hidden = !mine;
    column.querySelector<HTMLElement>('[data-median]')!.hidden = !isMedian;
  }

  // The same numbers again, as a table. Rows are rebuilt rather than patched so that a
  // rating change cannot leave a stale "your answer" note on a row it has moved off.
  const rows = root.querySelector<HTMLElement>('[data-histogram-rows]');
  if (rows) {
    rows.replaceChildren(
      ...SCALE_POINTS.map((point) => {
        const notes: string[] = [];
        if (SCALE_ANCHORS[point]) notes.push(SCALE_ANCHORS[point]);
        if (aggregate.median === point) notes.push('median');
        if (iRated && myScore === point) notes.push('your answer');

        return row(String(point), String(aggregate.histogram[point] ?? 0), notes.join(', '));
      }),
      // Declining is on the same table because it is the same question, and off the scale
      // because it is not a position on it.
      row(
        NO_OPINION_LABEL,
        String(aggregate.noOpinionCount),
        iRated && myScore === null ? 'off the scale, your answer' : 'off the scale',
      ),
    );
  }

  // ── The statistics line ─────────────────────────────────────────────────────────────

  set(root, 'positions', String(aggregate.totalRaters));
  set(root, 'opinions', String(aggregate.opinionCount));
  set(root, 'median', aggregate.median === null ? 'none yet' : String(aggregate.median));

  // An em dash and not a 0. Nobody has expressed an opinion, and 0 is a position on this
  // scale meaning strong disagreement — the same reason the column above is not filled either.
  set(root, 'mean', aggregate.mean === null ? '—' : aggregate.mean.toFixed(2));

  // The two export-time figures. Their wrappers stay hidden when the number is unavailable, so
  // the line ends after the mean rather than trailing two zeros.
  figure(root, 'contributions', counts?.contributions);
  figure(root, 'changed', counts?.positionChanges);

  // ── Where the off-scale answers are, in words ───────────────────────────────────────
  // They are not in the chart, because "outside my expertise" is not a position on a scale of
  // agreement, and they are not at 5, because a declared non-opinion is not a neutral opinion.
  // So they are stated. The reader's own decline is named first: they looked for their marker
  // on the chart and it is not there, and this is the sentence that answers that.
  const offscale = root.querySelector<HTMLElement>('[data-offscale]');
  if (offscale) {
    const others = aggregate.noOpinionCount - (iRated && myScore === null ? 1 : 0);
    const lines: string[] = [];

    if (iRated && myScore === null) {
      lines.push(
        'You answered “no opinion, or outside my expertise”, which is off the scale rather ' +
          'than in the middle of it, so you are not on the chart.',
      );
    }

    if (others > 0) {
      lines.push(
        others === 1
          ? '1 other person answered off the scale, for the same reason.'
          : `${others} other people answered off the scale.`,
      );
    } else if (!lines.length && aggregate.noOpinionCount > 0) {
      lines.push(
        aggregate.noOpinionCount === 1
          ? '1 person answered “no opinion, or outside my expertise”, which is off the scale.'
          : `${aggregate.noOpinionCount} people answered “no opinion, or outside my ` +
              'expertise”, which is off the scale.',
      );
    }

    offscale.textContent = lines.join(' ');
    offscale.hidden = lines.length === 0;
  }

  root.hidden = false;
}

/** A figure that is present or absent rather than present or zero. */
function figure(root: HTMLElement, stat: string, value: number | undefined): void {
  const wrapper = root.querySelector<HTMLElement>(`[data-figure="${stat}"]`);
  if (!wrapper) return;

  const known = typeof value === 'number' && Number.isFinite(value);
  if (known) set(root, stat, String(value));
  wrapper.hidden = !known;
}

function row(score: string, people: string, notes: string): HTMLTableRowElement {
  const tr = document.createElement('tr');

  const th = document.createElement('th');
  th.scope = 'row';
  th.textContent = score;

  const count = document.createElement('td');
  count.textContent = people;

  const note = document.createElement('td');
  note.textContent = notes;

  tr.append(th, count, note);
  return tr;
}

function set(root: HTMLElement, stat: string, value: string): void {
  const target = root.querySelector<HTMLElement>(`[data-stat="${stat}"]`);
  if (target) target.textContent = value;
}
