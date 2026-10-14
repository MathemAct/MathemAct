/**
 * The second half of answering a claim: the reason.
 *
 * Joining a claim somebody else proposed means a position **and** a reason, submitted together —
 * either endorsing contributions already on the page, or writing one's own. The rule lives in the
 * database (`ratings_require_a_contribution`, migration 20261011110000); this module is how the
 * form agrees with it, and it never stands in for it.
 *
 * It is shared by `/opinions/<id>/` and `/opinions/view/`, which own the submit handler and the
 * reveal. What lives here is everything between the scale and the submit button: which
 * contributions are offered, whether a reason is required right now, and what to send.
 *
 * **When a reason is required** mirrors the constraint exactly:
 *
 *   - a point on the scale, not "no opinion" — declining needs no reason;
 *   - and a first answer, or a move from "no opinion" to a score — a score-to-score change is free;
 *   - and nothing already given on this claim — a contribution of one's own, or an endorsement.
 *
 * Where this module cannot know something (an endorsement made in another tab), it errs towards
 * asking, and the database is the one that decides.
 */
import { ANSWER_NEEDS_A_REASON, type AnswerEndorsement } from './claims';
import type { EndorsementKind } from './endorsements';
import { syncCounters, wireCounters } from './forms';
import { OFF_SCALE_KEY, positionLabel } from './positions';

export { ANSWER_NEEDS_A_REASON };

export interface Reader {
  readonly userId: string | null;
  /** Whether they hold a rating on this claim already, and what it is. */
  readonly rated: boolean;
  readonly previousScore: number | null;
  /** A live contribution of their own, or any endorsement, on this claim. */
  readonly alreadyContributed: boolean;
  /** Contributions they have already endorsed. Not offered again — they are managed below. */
  readonly endorsed: ReadonlySet<string>;
}

export interface AnswerReason {
  setReader(reader: Reader): void;
  /** Whether the current choice on the scale needs a reason to be saved. */
  required(): boolean;
  /** What to send. Only what the reader can see counts: a choice in a list they hid does not. */
  collect(): { body: string; endorsements: AnswerEndorsement[] };
  /** Move the keyboard to the first thing that would satisfy the requirement. */
  focus(): void;
  /** After a successful save: what was sent is now part of the record, and the form resets. */
  saved(sent: { score: number | null; body: string; endorsements: readonly AnswerEndorsement[] }): void;
}

export function wireAnswerReason(form: HTMLFormElement, scaleName = 'score'): AnswerReason | null {
  const root = form.querySelector<HTMLElement>('[data-reason]');
  if (!root) return null;

  // Aliased for the hoisted functions below; see CLAUDE.md on narrowing.
  const section = root;

  const optional = section.querySelector<HTMLElement>('[data-reason-optional]');
  const hint = section.querySelector<HTMLElement>('[data-reason-hint]');
  const hereList = section.querySelector<HTMLElement>('[data-reason-here]');
  const hereEmpty = section.querySelector<HTMLElement>('[data-reason-here-empty]');
  const othersToggle = section.querySelector<HTMLButtonElement>('[data-reason-others-toggle]');
  const othersWrap = section.querySelector<HTMLElement>('[data-reason-others]');
  const othersList = section.querySelector<HTMLElement>('[data-reason-others-list]');
  const writeReveal = section.querySelector<HTMLButtonElement>('[data-reason-write-reveal]');
  const writeField = section.querySelector<HTMLElement>('[data-reason-write]');
  const body = section.querySelector<HTMLTextAreaElement>('[data-reason-body]');

  /** In the order the build wrote them, which is the order they are put back in. */
  const candidates = [...section.querySelectorAll<HTMLElement>('[data-candidate]')];

  let reader: Reader = {
    userId: null,
    rated: false,
    previousScore: null,
    alreadyContributed: false,
    endorsed: new Set(),
  };

  let othersOpen = false;
  /** Set once the reader asks to write, so a change of score does not fold the box away. */
  let writeOpened = false;

  wireCounters(form);

  function selectedKey(): string | undefined {
    return form.querySelector<HTMLInputElement>(`input[name="${scaleName}"]:checked`)?.value;
  }

  /** Their own contributions, and ones they have already endorsed, are not offered. */
  function excluded(candidate: HTMLElement): boolean {
    const id = candidate.dataset.commentId ?? '';
    return (
      (!!reader.userId && candidate.dataset.author === reader.userId) || reader.endorsed.has(id)
    );
  }

  function required(): boolean {
    const key = selectedKey();
    if (key === undefined || key === OFF_SCALE_KEY) return false;
    const takingAPosition = !reader.rated || reader.previousScore === null;
    return takingAPosition && !reader.alreadyContributed;
  }

  function hintText(key: string | undefined): string {
    if (key === OFF_SCALE_KEY) {
      return 'Optional when you have no opinion. If something here says why the question is hard to judge, you can endorse it.';
    }
    if (reader.rated && reader.previousScore !== null) {
      return 'Optional when you change your answer. Add a reason if yours has changed too.';
    }
    if (reader.alreadyContributed) {
      return 'Optional: you have already given a reason on this claim.';
    }
    return 'Endorse a contribution that captures your view, or write your own. It is recorded with your position.';
  }

  function refresh(): void {
    const key = selectedKey();
    section.hidden = key === undefined;
    if (key === undefined) return;

    let here = 0;
    let others = 0;

    for (const candidate of candidates) {
      if (excluded(candidate)) {
        candidate.hidden = true;
        continue;
      }

      candidate.hidden = false;
      if (candidate.dataset.position === key) {
        hereList?.append(candidate);
        here += 1;
      } else {
        othersList?.append(candidate);
        others += 1;
      }
    }

    if (optional) optional.hidden = required();
    if (hint) hint.textContent = hintText(key);

    if (hereEmpty) {
      hereEmpty.hidden = here > 0;
      hereEmpty.textContent =
        here + others === 0
          ? 'Nobody else has written a contribution yet, so yours would be the first.'
          : `Nobody has written from ${positionLabel(key === OFF_SCALE_KEY ? null : Number(key))} yet.`;
    }

    if (othersToggle) {
      othersToggle.hidden = others === 0;
      othersToggle.setAttribute('aria-expanded', String(othersOpen));
      othersToggle.textContent = othersOpen
        ? 'Hide contributions from other positions'
        : `Show ${others} ${others === 1 ? 'contribution' : 'contributions'} from other positions`;
    }
    if (othersWrap) othersWrap.hidden = others === 0 || !othersOpen;

    // Open from the start when there is nothing at this position to endorse: the box is
    // collapsed only so that somebody about to retype an argument sees it first, and here there
    // is nothing to see first.
    const writeOpen = writeOpened || here === 0;
    if (writeField) writeField.hidden = !writeOpen;
    if (writeReveal) writeReveal.hidden = writeOpen;
  }

  form.addEventListener('change', (event) => {
    const target = event.target as HTMLInputElement | null;
    if (target?.name === scaleName) refresh();
  });

  othersToggle?.addEventListener('click', () => {
    othersOpen = !othersOpen;
    refresh();
  });

  writeReveal?.addEventListener('click', () => {
    writeOpened = true;
    refresh();
    body?.focus();
  });

  function visibleCandidates(): HTMLElement[] {
    return candidates.filter(
      (candidate) =>
        !candidate.hidden &&
        (hereList?.contains(candidate) || (othersOpen && othersList?.contains(candidate))),
    );
  }

  function collect(): { body: string; endorsements: AnswerEndorsement[] } {
    const endorsements: AnswerEndorsement[] = [];

    for (const candidate of visibleCandidates()) {
      const chosen = candidate.querySelector<HTMLInputElement>('input[type="radio"]:checked');
      const kind = chosen?.value;
      if (kind === 'captures_my_view' || kind === 'agree_position_not_reason') {
        endorsements.push({
          commentId: candidate.dataset.commentId ?? '',
          kind: kind as EndorsementKind,
        });
      }
    }

    return {
      body: writeField && !writeField.hidden ? (body?.value.trim() ?? '') : '',
      endorsements,
    };
  }

  function focus(): void {
    const first =
      hereList?.querySelector<HTMLInputElement>('input[type="radio"]') ??
      (writeField && !writeField.hidden ? body : null) ??
      writeReveal;
    first?.focus();
  }

  function saved(sent: {
    score: number | null;
    body: string;
    endorsements: readonly AnswerEndorsement[];
  }): void {
    const endorsed = new Set(reader.endorsed);
    for (const e of sent.endorsements) endorsed.add(e.commentId);

    reader = {
      ...reader,
      rated: true,
      previousScore: sent.score,
      alreadyContributed:
        reader.alreadyContributed || sent.body !== '' || sent.endorsements.length > 0,
      endorsed,
    };

    if (body) body.value = '';
    syncCounters(form);

    for (const candidate of candidates) {
      const neither = candidate.querySelector<HTMLInputElement>('input[type="radio"][value=""]');
      if (neither) neither.checked = true;
    }

    writeOpened = false;
    othersOpen = false;
    refresh();
  }

  function setReader(next: Reader): void {
    reader = next;
    refresh();
  }

  refresh();

  return { setReader, required, collect, focus, saved };
}
