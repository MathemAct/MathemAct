/**
 * The shape of a report: its vocabularies, its limits, and the words used to ask for
 * each field.
 *
 * This file is the form's script. It exists as data rather than as markup because the same
 * words have to appear in three places that must not drift — the submission form, the
 * display of a submitted report, and eventually the disclosure template a journal could
 * adopt. A label written into a template is a label that gets reworded in one of the three.
 *
 * Every cap below mirrors a CHECK constraint in supabase/migrations/20260815100200_practices.sql
 * and 20260820100000_report_schema_v2.sql. The database is the truth and this is the
 * convenience: PostgREST is a public endpoint and our form is not the only way to reach it.
 * When a cap changes, it changes in the migration first and here second.
 *
 * On the microcopy
 * ----------------
 * Every field gets one line saying what it is for, and the ones where people reliably guess
 * wrong get a real example. The examples are deliberately ordinary — a lemma, a literature
 * search, a translation — because an example of a spectacular result would teach people
 * that spectacular results are what belongs here, and they are not. Failures are.
 */
import type { Outcome } from './status';

/**
 * Which version of the reporting standard this build writes.
 *
 * Bumped by a migration when a field or a vocabulary changes, and carried on every row so
 * that an analysis can tell a report that answered a question from one that was never asked
 * it. Version 2 added career stage, the secondary task types, the prompts, the supporting
 * links, and the five scales. Version 3 added "Did you learn something new?" and its note.
 */
export const SCHEMA_VERSION = 3;

// ── Limits ────────────────────────────────────────────────────────────────────────────
// Mirrors the CHECK constraints. A counter is shown against every one of these, because a
// cap you discover by being rejected is a cap that cost you the paragraph you just wrote.

export const REPORT_LIMITS = {
  title: 120,
  areaOther: 80,
  aim: 600,
  method: 6000,
  outcomeNotes: 1500,
  verification: 3000,
  prompts: 4000,
  transcriptExcerpt: 20000,
  transcriptUrl: 500,
  caveats: 2000,
  learnedNotes: 1000,
  toolName: 80,
  toolVersion: 40,
  toolRole: 60,
  referenceUrl: 500,
  /** Roughly seventy days. High enough never to reject an honest answer. */
  timeSpentMinutes: 100000,
  /** Six rows already describe one session unusually carefully. Past that the rows stop
   *  describing a session and start describing a year, which is a second report. */
  tools: 6,
  references: 8,
  /** Anything else the tool was asked to do. Three, because a fourth is the whole
   *  vocabulary and says nothing. */
  taskSecondary: 3,
} as const;

/** The site's 11-point scale, same anchors as the agreement scale. */
export const CONFIDENCE = { min: 0, max: 10 } as const;

/** Nothing before this is plausible as AI-assisted mathematical work, and a mistyped year
 *  is the thing this catches. Mirrors report_tools_used_on_lower_bound. */
export const EARLIEST_TOOL_USE = '2015-01-01';

// ── Vocabularies ──────────────────────────────────────────────────────────────────────
// Values match the Postgres enums and CHECK constraints exactly. Nothing translates between
// the database, the form, and the export.

export interface Choice<T extends string> {
  readonly value: T;
  readonly label: string;
  /** One line. Shown beside the option, not in a tooltip. */
  readonly hint?: string;
}

/**
 * Area is **why you were working**. Task type is **what the tool was asked to do**.
 *
 * Keeping those two apart is the whole reason either is worth filtering on: `programming`
 * and formal verification were being offered here in an earlier draft of this list, which
 * mixes the axes and makes both useless — "research" and "programming" are not alternatives,
 * they are answers to different questions.
 */
export const AREAS = [
  { value: 'research', label: 'Research', hint: 'Work intended to produce new mathematics.' },
  { value: 'learning', label: 'Learning', hint: 'Understanding something already known, for yourself.' },
  { value: 'teaching', label: 'Teaching', hint: 'Preparing or delivering material for others.' },
  { value: 'writing', label: 'Writing', hint: 'Exposition, papers, talks, notes.' },
  { value: 'outreach', label: 'Outreach', hint: 'Explaining mathematics to people outside it.' },
  {
    value: 'administration',
    label: 'Administration',
    hint: 'Grant text, reports, reviewing logistics, correspondence.',
  },
  { value: 'other', label: 'Other', hint: 'Say which below.' },
] as const satisfies readonly Choice<string>[];

export type Area = (typeof AREAS)[number]['value'];

export const TASK_TYPES = [
  { value: 'literature_search', label: 'Literature search', hint: 'Finding what is already known.' },
  {
    value: 'comprehension',
    label: 'Reading and understanding',
    hint: 'Working through a paper, or filling in background you lacked.',
  },
  {
    value: 'brainstorming',
    label: 'Brainstorming',
    hint: 'Generating ideas, approaches, or framings without yet committing to a formal claim.',
  },
  {
    value: 'conjecture_generation',
    label: 'Conjecture generation',
    hint: 'Proposing statements, or approaches, to try.',
  },
  { value: 'proof_drafting', label: 'Proof drafting', hint: 'Producing an argument or an outline of one.' },
  { value: 'proof_checking', label: 'Proof checking', hint: 'Looking for gaps in an argument you have.' },
  { value: 'formalisation', label: 'Formalisation', hint: 'Stating mathematics in a proof assistant.' },
  { value: 'computation', label: 'Computation', hint: 'Calculating, searching, or generating examples.' },
  {
    value: 'example_counterexample',
    label: 'Produce example or counterexample',
    hint: 'Constructing an instance satisfying given conditions, or a counterexample to a statement.',
  },
  {
    value: 'programming',
    label: 'Programming',
    hint: 'Writing or debugging code that is not a formal proof.',
  },
  {
    value: 'exposition',
    label: 'Exposition',
    hint: 'Explaining known mathematics readably. Includes slides and notes.',
  },
  { value: 'translation', label: 'Translation', hint: 'Between languages, or between notations.' },
  {
    value: 'referee_work',
    label: 'Referee work',
    hint: 'Reading and reporting on somebody else’s work.',
  },
  { value: 'other', label: 'Other', hint: 'Say which in the account below.' },
] as const satisfies readonly Choice<string>[];

export type TaskType = (typeof TASK_TYPES)[number]['value'];

/**
 * Career stage. Coarse on purpose, optional on purpose.
 *
 * There is no `prefer_not_to_say`: the field is optional, so a blank already says that, and
 * offering both makes the blank ambiguous. Institution, country and year of birth are
 * deliberately not collected — a report is permanent and under CC BY, and career stage plus
 * a subject area plus a date is already close to identifying in a small field.
 */
export const CAREER_STAGES = [
  { value: 'undergraduate', label: 'Undergraduate' },
  { value: 'masters', label: 'Master’s student' },
  { value: 'doctoral', label: 'Doctoral student' },
  { value: 'postdoctoral', label: 'Postdoctoral' },
  { value: 'faculty', label: 'Faculty' },
  { value: 'researcher_outside_academia', label: 'Researcher outside academia' },
  { value: 'teacher', label: 'Teacher' },
  { value: 'independent', label: 'Independent' },
  { value: 'other', label: 'Other' },
] as const satisfies readonly Choice<string>[];

export type CareerStage = (typeof CAREER_STAGES)[number]['value'];

export const WAS_PUBLISHED = [
  { value: 'yes',            label: 'Yes' },
  { value: 'not_yet',        label: 'Not yet' },
  { value: 'no',             label: 'No, and I do not expect it to be' },
  { value: 'not_applicable', label: 'Not applicable' },
] as const satisfies readonly Choice<string>[];

export type WasPublished = (typeof WAS_PUBLISHED)[number]['value'];

export function wasPublishedLabel(value: string): string {
  return WAS_PUBLISHED.find((c) => c.value === value)?.label ?? value;
}

export const TIME_SAVED = [
  { value: 'none',         label: 'No time saved' },
  { value: 'few_minutes',  label: 'A few minutes' },
  { value: 'about_an_hour', label: 'About an hour' },
  { value: 'few_hours',    label: 'A few hours' },
  { value: 'about_a_day',  label: 'About a day' },
  { value: 'few_days',     label: 'A few days' },
  { value: 'about_a_week', label: 'About a week' },
  { value: 'more',         label: 'More' },
  { value: 'cost_more',    label: 'It cost me more time than it saved' },
] as const satisfies readonly Choice<string>[];

export type TimeSaved = (typeof TIME_SAVED)[number]['value'];

export function timeSavedLabel(value: string): string {
  return TIME_SAVED.find((c) => c.value === value)?.label ?? value;
}

/**
 * The three outcomes, in the order they appear on the form.
 *
 * They are ordered by what happened rather than by how good it is, and the interface gives
 * them identical weight: same size, same border, same type. A corpus of only successes is
 * worthless and reads as advertising, and failure modes are precisely what nobody
 * publishes. If a future change makes one of these smaller, quieter, or last, it has broken
 * the thing the corpus is for.
 */
export const OUTCOME_CHOICES = [
  {
    value: 'worked',
    label: 'It worked',
    hint: 'The result was what you needed, and it held up when you checked it.',
  },
  {
    value: 'partial',
    label: 'It partly worked',
    hint: 'Some of it was usable. The rest was wrong, irrelevant, or needed redoing.',
  },
  {
    value: 'failed',
    label: 'It did not work',
    hint: 'It produced nothing usable, or produced something confidently wrong.',
  },
] as const satisfies readonly Choice<Outcome>[];

/**
 * How far the author thinks this carries.
 *
 * Three named answers rather than an eleven-point scale, and that is not a shortcut. It is a
 * guess for everybody who answers it, and a number would dress a guess as a measurement.
 */
export const GENERALISATIONS = [
  { value: 'task_specific', label: 'Very task-specific' },
  { value: 'similar_tasks', label: 'Likely useful in similar tasks' },
  { value: 'broadly', label: 'Likely useful across many areas of mathematics' },
] as const satisfies readonly Choice<string>[];

export type Generalises = (typeof GENERALISATIONS)[number]['value'];

/**
 * What a supporting link points at.
 *
 * There is deliberately **no AI-conversation kind**. A share link belongs in `transcriptUrl`
 * in the Transcript section, under the rule that it may never stand alone; a second route in
 * here would be a way round that rule rather than a new kind of thing.
 */
export const REFERENCE_KINDS = [
  { value: 'paper', label: 'Paper or preprint' },
  { value: 'code', label: 'Code repository' },
  { value: 'notebook', label: 'Notebook' },
  { value: 'formalisation', label: 'Formalisation — Lean, Coq, Isabelle' },
  { value: 'overleaf', label: 'Overleaf project' },
  { value: 'dataset', label: 'Dataset' },
  { value: 'figure', label: 'Figure or image' },
  { value: 'slides', label: 'Slides or video' },
  { value: 'other', label: 'Other' },
] as const satisfies readonly Choice<string>[];

export type ReferenceKind = (typeof REFERENCE_KINDS)[number]['value'];

/** Kinds that mean somebody can run or check the work, which is its own filter. */
export const EXECUTABLE_REFERENCE_KINDS: readonly ReferenceKind[] = [
  'code',
  'notebook',
  'formalisation',
];

/**
 * Hosts where a link is usually readable only by the person who made it.
 *
 * A warning and never a refusal. Plenty of Overleaf and Drive links are shared correctly,
 * and a database that refused them would refuse those too — but "check this is readable
 * without signing in" is the single most useful thing to say next to one of these boxes.
 */
export const LOGIN_WALLED_HOSTS = [
  'drive.google.com',
  'docs.google.com',
  'dropbox.com',
  'overleaf.com',
  'sharepoint.com',
  'onedrive.live.com',
] as const;

/**
 * Suggested tool names, offered as a datalist and never as a closed list. Free text is
 * always accepted: a controlled vocabulary of tools would be out of date within a month,
 * and the interesting accounts are the ones using something nobody thought to list.
 */
export const COMMON_TOOLS = [
  'ChatGPT',
  'GPT-5',
  'Claude',
  'Gemini',
  'DeepSeek',
  'Copilot',
  'Lean',
  'Mathlib',
  'Rocq',
  'Isabelle',
  'Agda',
  'SageMath',
  'Mathematica',
  'Maple',
  'MATLAB',
  'Magma',
  'GAP',
  'PARI/GP',
  'Macaulay2',
  'Singular',
  'SymPy',
  'OEIS',
  'AlphaProof',
] as const;

// ── The scales ────────────────────────────────────────────────────────────────────────
/**
 * Five scales, all 0 to 10, all discrete radios, none with a default.
 *
 * Three rules, and each of them changes what the numbers mean.
 *
 * **No pre-selected value.** An unanswered group stores null, which is what makes every one
 * of these skippable without a "rather not say" control on each row. A slider cannot do
 * this: `input type=range` forces a value, that value anchors the answer, and it reads to a
 * screen reader as a number with no anchors.
 *
 * **Only the two ends are labelled.** Mid-point labels get argued with and slow people down,
 * and the argument is never about the tool.
 *
 * **Two of them are conditional.** Novelty is meaningless for a teaching-prep session and
 * understanding gained is meaningless for a literature search, and seven rows of radios is
 * an invitation to straight-line the lot. A hidden scale submits null, never 0 — a 0 would
 * put "no help at all" into the corpus for a question nobody was asked.
 */
export interface RatingScaleSpec {
  /** The column, and the radio group's name. */
  readonly key: RatingKey;
  readonly prompt: string;
  /** Two or three words, for the display side. A report page shows nine of these in a
   *  definition list and the questions would be nine sentences down the margin. */
  readonly short: string;
  readonly low: string;
  readonly high: string;
  /** Absent means always shown. */
  readonly when?: {
    readonly areas: readonly Area[];
    readonly tasks: readonly TaskType[];
  };
}

export type RatingKey =
  | 'rating_helpfulness'
  | 'rating_trust_before_checking'
  | 'rating_verification_effort'
  | 'rating_novelty'
  | 'rating_understanding_gained';

export const RATING_SCALES: readonly RatingScaleSpec[] = [
  {
    key: 'rating_helpfulness',
    prompt: 'How helpful was the tool for this task?',
    short: 'Helpfulness',
    low: 'no help at all',
    high: 'did the task',
  },
  {
    key: 'rating_trust_before_checking',
    prompt: 'How much did you trust the output before you checked it?',
    short: 'Trust before checking',
    low: 'not at all',
    high: 'completely',
  },
  {
    key: 'rating_verification_effort',
    prompt: 'How much work was checking it?',
    short: 'Effort to check',
    low: 'a glance',
    high: 'as much as doing it myself',
  },
  {
    key: 'rating_novelty',
    prompt: 'Did it suggest anything you would not have thought of?',
    short: 'Novelty',
    low: 'nothing new',
    high: 'something genuinely new to me',
    when: {
      areas: ['research'],
      tasks: ['conjecture_generation', 'proof_drafting', 'computation'],
    },
  },
  {
    key: 'rating_understanding_gained',
    prompt: 'Did your understanding improve?',
    short: 'Understanding gained',
    low: 'not at all',
    high: 'substantially',
    when: {
      areas: ['learning', 'teaching', 'outreach'],
      tasks: ['comprehension', 'exposition', 'literature_search'],
    },
  },
];

/**
 * Whether a conditional scale applies to the answers given so far.
 *
 * Shared between the form, which shows or hides the row, and the submission, which sends
 * null for anything hidden. Two copies of this rule would eventually disagree, and the
 * disagreement would be silent: a 7 stored against a question the author never saw.
 */
export function scaleApplies(
  scale: RatingScaleSpec,
  area: string | undefined,
  taskPrimary: string | undefined,
  taskSecondary: readonly string[],
): boolean {
  if (!scale.when) return true;

  if (area && (scale.when.areas as readonly string[]).includes(area)) return true;

  const tasks = scale.when.tasks as readonly string[];
  if (taskPrimary && tasks.includes(taskPrimary)) return true;

  return taskSecondary.some((task) => tasks.includes(task));
}

// ── The questions ─────────────────────────────────────────────────────────────────────
// One line each, and a real example wherever people reliably guess wrong about the level
// of detail wanted.

export const FIELD_COPY = {
  title: {
    example: 'Check a lemma in additive combinatorics with a proof assistant',
  },
  aim: {
    example:
      'I had a lemma I believed but could not see a clean proof of, and wanted to know whether it was true before spending a week on it.',
  },
  method: {
    example:
      '1. Stated the lemma in Lean 4 with Mathlib.\n2. Asked the model for a proof sketch.\n3. It suggested induction on the size of the sumset.\n4. Translated the sketch into tactics and closed three of five goals.\n5. Did the remaining two by hand.',
  },
  outcomeNotes: {
    example:
      'The induction was the right idea but the base case it gave was for the wrong statement. Two of the five goals closed directly; the others needed a hypothesis it had silently assumed.',
  },
  verification: {
    hint: 'How you established the result was correct — or established that it was not.',
    example:
      'Lean accepted the final proof, so the formal statement is verified. I checked separately that the formal statement says what I meant by rederiving the informal version by hand.',
  },
  prompts: {
    example:
      'Let A be a finite subset of Z with |A+A| ≤ 3|A|. Is it true that A is contained in an arithmetic progression of length at most C|A|? Give a proof or a counterexample, and state any hypothesis you add.',
  },
  transcriptExcerpt: {
    example: '',
  },
  transcriptUrl: {
    hint: 'A share link, if you have one. Supplementary only.',
    example: '',
  },
  caveats: {
    example:
      'I would state the hypotheses in full before asking. Most of the wasted time came from it filling in an assumption I had left implicit.',
  },
  learned: {
    hint: 'About the mathematics, the tool, or how to work with it — say which in the box.',
    example:
      'The counterexample it gave showed that my hypothesis was too strong, and why the usual induction cannot work without it.',
  },
} as const;

// ── Looking a label up ────────────────────────────────────────────────────────────────
// The display layer needs the same words the form used. Falling back to the raw value
// rather than to an empty string, so that a vocabulary widened by a migration but not yet
// here renders as `proof_repair` — visibly unfinished — instead of as a blank.

export function areaLabel(value: string): string {
  return AREAS.find((choice) => choice.value === value)?.label ?? value;
}

export function taskTypeLabel(value: string): string {
  return TASK_TYPES.find((choice) => choice.value === value)?.label ?? value;
}

export function outcomeLabel(value: string): string {
  return OUTCOME_CHOICES.find((choice) => choice.value === value)?.label ?? value;
}

export function careerStageLabel(value: string): string {
  return CAREER_STAGES.find((choice) => choice.value === value)?.label ?? value;
}

export function generalisesLabel(value: string): string {
  return GENERALISATIONS.find((choice) => choice.value === value)?.label ?? value;
}

export function referenceKindLabel(value: string): string {
  return REFERENCE_KINDS.find((choice) => choice.value === value)?.label ?? value;
}

// ── "For counting", as terms and values ───────────────────────────────────────────────

export interface Fact {
  readonly term: string;
  readonly value: string;
}

/** The structural minimum this needs. Declared here rather than imported from reports.ts,
 *  which imports *this* file — and a display helper has no business knowing what a corpus
 *  row is anyway. */
export interface CountedInput {
  readonly careerStage: string | null;
  readonly timeSpentMinutes: number | null;
  readonly ratings: Readonly<Record<RatingKey, number | null>>;
  readonly timeSaved: string | null;
  readonly authorConfidence: number | null;
  readonly generalises: string | null;
  readonly wasPublished: string | null;
  readonly wasDisclosed: boolean | null;
  /** Optional because an export written before schema version 3 has no such key. */
  readonly learnedSomething?: boolean | null;
}

/**
 * The structured answers on a report, as a list of terms and values, in one place.
 *
 * Three pages render this — the static report page, the runtime view page, and eventually
 * whatever a journal makes of the disclosure template — and two of them build their DOM in
 * different languages. A term written in each would drift on the first reword, and the
 * direction it drifts in matters: these are the answers somebody will read as data.
 *
 * A null is skipped rather than rendered as "not answered". Every one of these is optional
 * and a blank is a real answer, so a page listing nine "not answered" rows would be reading
 * the corpus's own rule back to it as a failure.
 */
export function countedFacts(input: CountedInput): Fact[] {
  const facts: Fact[] = [];

  if (input.careerStage) {
    facts.push({ term: 'Career stage', value: careerStageLabel(input.careerStage) });
  }

  if (input.timeSpentMinutes !== null) {
    facts.push({ term: 'Time spent', value: `${input.timeSpentMinutes} min` });
  }

  for (const scale of RATING_SCALES) {
    const answer = input.ratings[scale.key];
    if (answer !== null && answer !== undefined) {
      facts.push({ term: scale.short, value: `${answer} / 10` });
    }
  }

  if (input.timeSaved) {
    facts.push({ term: 'Time saved', value: timeSavedLabel(input.timeSaved) });
  }

  if (input.authorConfidence !== null) {
    facts.push({ term: 'Author confidence', value: `${input.authorConfidence} / 10` });
  }

  if (input.generalises) {
    facts.push({ term: 'Generalises', value: generalisesLabel(input.generalises) });
  }

  if (input.wasPublished) {
    facts.push({ term: 'Published', value: wasPublishedLabel(input.wasPublished) });
  }

  if (input.wasDisclosed !== null) {
    facts.push({
      term: 'Disclosed in the paper',
      value: input.wasDisclosed ? 'yes' : 'no',
    });
  }

  // Said the same way for both answers, and shown whatever the outcome: a failure that taught
  // something is a "yes" like any other, and a "no" is not a lesser contribution.
  if (typeof input.learnedSomething === 'boolean') {
    facts.push({
      term: 'Learned something new',
      value: input.learnedSomething ? 'yes' : 'no',
    });
  }

  return facts;
}

// ── The sections, in the order the form asks for them ─────────────────────────────────
// Used by the progress indicator, which counts sections rather than fields so that "6 of
// 16" means something to somebody deciding whether to start.
//
// Sixteen, and the arithmetic is worth writing down because the specification this was
// built from gives two different totals. Version 1 had twelve. Version 2 adds About you,
// Prompts and Supporting material — three — and relabels Caveats rather than dropping it,
// which the spec's own section table omitted while §3 and §8 both kept the field. Twelve
// plus three is fifteen; nothing was added that is not in the spec, and nothing the spec
// keeps was quietly lost to make a count come out. Version 3 appends "What you learned" as
// the sixteenth, last rather than after Outcome so that nothing is renumbered.

export interface Section {
  readonly id: string;
  readonly number: number;
  readonly title: string;
  /** Whether an answer is required for the submission to be accepted. */
  readonly required: boolean;
}

export const SECTIONS: readonly Section[] = [
  { id: 'title', number: 1, title: 'Title', required: true },
  { id: 'area', number: 2, title: 'Area', required: true },
  { id: 'task-type', number: 3, title: 'Task type', required: true },
  { id: 'tools', number: 4, title: 'Tools used', required: true },
  { id: 'about-you', number: 5, title: 'About you', required: false },
  { id: 'aim', number: 6, title: 'What you were trying to do', required: true },
  { id: 'method', number: 7, title: 'What you actually did', required: true },
  { id: 'outcome', number: 8, title: 'Outcome', required: true },
  { id: 'verification', number: 9, title: 'How you verified correctness', required: true },
  { id: 'prompts', number: 10, title: 'Prompts', required: false },
  { id: 'transcript', number: 11, title: 'Transcript', required: false },
  {
    id: 'caveats',
    number: 12,
    title: 'What you would tell someone trying this',
    required: false,
  },
  { id: 'tags', number: 13, title: 'Subject areas', required: false },
  { id: 'references', number: 14, title: 'Supporting material', required: false },
  { id: 'counting', number: 15, title: 'So this can be counted', required: false },
  { id: 'learned', number: 16, title: 'What you learned', required: false },
];

/** The denominator in "4 / 15", in one place so the markup cannot drift from the list. */
export const SECTION_COUNT = SECTIONS.length;
