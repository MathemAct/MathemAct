/**
 * The behaviour of the report form, once — for /reports/new/ and /account/edit-submission/
 * both.
 *
 * `ReportFields.astro` holds the markup; this holds everything that reads or writes it. The
 * two were copied between those pages for as long as the form was twelve sections of plain
 * fields, and that stopped being survivable the moment version 2 added conditional scales.
 * A rule written twice is a rule that will disagree with itself, and here the disagreement
 * would be silent: a scale shown on one page and not the other stores a number against a
 * question the author never saw.
 *
 * Written as a class rather than as loose functions for a reason that is specific to this
 * project. `const root = document.querySelector(...)` narrowed by an `if` stops being
 * narrowed inside a hoisted `function` declaration, and the fix people reach for is a `!` at
 * each use — `CommentThread.astro` accumulated four and `reports/index.astro` six, with five
 * real `astro check` errors sitting between them through a green build. A field assigned once
 * in a constructor is narrowed everywhere, for free, permanently.
 *
 * What this file does *not* do: decide whether a save is allowed, or what the caps are. The
 * database decides the first and states the second; every limit here is read from
 * report-schema.ts, which mirrors the CHECK constraints.
 */
import {
  EARLIEST_TOOL_USE,
  LOGIN_WALLED_HOSTS,
  RATING_SCALES,
  REFERENCE_KINDS,
  REPORT_LIMITS,
  SECTIONS,
  scaleApplies,
} from './report-schema';
import type { Area, CareerStage, Generalises, RatingKey, TaskType } from './report-schema';
import type { Outcome } from './status';
import { loadTags, ratingsFor } from './reports';
import type {
  EditableReportForEdit,
  Ratings,
  Submission,
  SubmissionReference,
  SubmissionTool,
} from './reports';
import { query, setFieldError, syncCounters } from './forms';
import {
  referenceWarning,
  validateOptionalText,
  validateReference,
  validateRequiredText,
  validateTimeSpent,
  validateTool,
  validateTranscriptUrl,
  validateVerification,
} from './validation';

/** A field id, or `section-<id>`, to scroll to and focus. Null when everything passed. */
export type FirstProblem = string | null;

const REFERENCE_KIND_VALUES = REFERENCE_KINDS.map((kind) => kind.value);

export class ReportForm {
  private readonly toolList: HTMLUListElement;
  private readonly toolTemplate: HTMLTemplateElement;
  private readonly referenceList: HTMLUListElement;
  private readonly referenceTemplate: HTMLTemplateElement;
  private readonly tagOptions: HTMLFieldSetElement;
  private readonly tagTemplate: HTMLTemplateElement;
  private readonly tagSearch: HTMLInputElement;
  private readonly tagStatus: HTMLElement;
  private readonly tagChosen: HTMLElement;
  private readonly areaOther: HTMLElement;
  private readonly disclosure: HTMLFieldSetElement;
  private readonly rights: HTMLElement;

  /** Unique-per-row suffix for the ids a `for`/`id` pair needs. A template cannot carry
   *  them: duplicated, every label points at the first row's field. */
  private sequence = 0;

  /** Tag codes to tick once the vocabulary has been fetched. The list is loaded
   *  asynchronously, so a draft or an existing report has to wait for it. */
  private pendingTags: string[] = [];

  constructor(
    private readonly form: HTMLFormElement,
    /** Called after anything this class changes, so the page can re-run its own refresh. */
    private readonly onChange: () => void,
  ) {
    this.toolList = query<HTMLUListElement>('[data-tool-list]', form);
    this.toolTemplate = query<HTMLTemplateElement>('[data-tool-template]', form);
    this.referenceList = query<HTMLUListElement>('[data-reference-list]', form);
    this.referenceTemplate = query<HTMLTemplateElement>('[data-reference-template]', form);
    this.tagOptions = query<HTMLFieldSetElement>('[data-tag-options]', form);
    this.tagTemplate = query<HTMLTemplateElement>('[data-tag-template]', form);
    this.tagSearch = query<HTMLInputElement>('[data-tag-search]', form);
    this.tagStatus = query<HTMLElement>('[data-tag-status]', form);
    this.tagChosen = query<HTMLElement>('[data-tag-chosen]', form);
    this.areaOther = query<HTMLElement>('[data-area-other]', form);
    this.disclosure = query<HTMLFieldSetElement>('[data-disclosure]', form);
    this.rights = query<HTMLElement>('[data-rights]', form);

    query<HTMLButtonElement>('[data-tool-add]', form).addEventListener('click', () => {
      const row = this.addTool();
      row.querySelector<HTMLInputElement>('[data-tool-name]')?.focus();
      this.onChange();
    });

    query<HTMLButtonElement>('[data-reference-add]', form).addEventListener('click', () => {
      const row = this.addReference();
      row.querySelector<HTMLSelectElement>('[data-reference-kind]')?.focus();
      this.onChange();
    });

    this.tagSearch.addEventListener('input', () => this.filterTags());
  }

  // ── Reading the answers ─────────────────────────────────────────────────────────────

  /** A text field's trimmed value, by id. */
  value(id: string): string {
    return (
      this.form
        .querySelector<HTMLInputElement | HTMLTextAreaElement>(`#${CSS.escape(id)}`)
        ?.value.trim() ?? ''
    );
  }

  /** The chosen value of a radio group, or undefined. An empty string counts as undefined:
   *  the "rather not say" radio in the disclosure group carries one. */
  checked(name: string): string | undefined {
    return (
      this.form.querySelector<HTMLInputElement>(`input[name="${name}"]:checked`)?.value ||
      undefined
    );
  }

  private box(id: string): boolean {
    return this.form.querySelector<HTMLInputElement>(`#${CSS.escape(id)}`)?.checked ?? false;
  }

  /** yes / no / not-yet, where "not yet" is genuinely unknown rather than false. */
  private tristate(name: string): boolean | null {
    const answer = this.checked(name);
    if (answer === 'yes') return true;
    if (answer === 'no') return false;
    return null;
  }

  taskSecondary(): TaskType[] {
    return [
      ...this.form.querySelectorAll<HTMLInputElement>(
        'input[name="task_secondary"]:checked',
      ),
    ].map((input) => input.value as TaskType);
  }

  /** One tool row, read off the element. `:scope >` is unnecessary here — a tool row cannot
   *  contain another — but the lookups are kept in one place so that a change to the markup
   *  is a change to one function rather than to four call sites. */
  private toolFrom(row: HTMLElement): SubmissionTool {
    return {
      name: row.querySelector<HTMLInputElement>('[data-tool-name]')?.value ?? '',
      version: row.querySelector<HTMLInputElement>('[data-tool-version]')?.value ?? '',
      usedOn: row.querySelector<HTMLInputElement>('[data-tool-date]')?.value ?? '',
      role: row.querySelector<HTMLInputElement>('[data-tool-role]')?.value ?? '',
    };
  }

  private referenceFrom(row: HTMLElement): SubmissionReference {
    return {
      kind: (row.querySelector<HTMLSelectElement>('[data-reference-kind]')?.value ??
        'other') as SubmissionReference['kind'],
      url: row.querySelector<HTMLInputElement>('[data-reference-url]')?.value ?? '',
    };
  }

  readTools(): SubmissionTool[] {
    return [...this.toolList.querySelectorAll<HTMLElement>('.tool-row')]
      .map((row) => this.toolFrom(row))
      // A row somebody added and left blank is not a refusal, it is an empty row.
      .filter((tool) => tool.name.trim() || tool.version.trim() || tool.usedOn);
  }

  readReferences(): SubmissionReference[] {
    return [...this.referenceList.querySelectorAll<HTMLElement>('.tool-row')]
      .map((row) => this.referenceFrom(row))
      .filter((reference) => reference.url.trim());
  }

  chosenTags(): string[] {
    return [
      ...this.tagOptions.querySelectorAll<HTMLInputElement>('.tag__input:checked'),
    ].map((input) => input.value);
  }

  /** Every scale as it stands in the DOM, before the conditional ones are nulled. */
  private ratingAnswers(): Ratings {
    const answers = {} as Record<RatingKey, number | null>;

    for (const scale of RATING_SCALES) {
      const chosen = this.checked(scale.key);
      answers[scale.key] = chosen === undefined ? null : Number(chosen);
    }

    return answers;
  }

  /** Everything the RPC needs, bar the tag codes, which are also read here. */
  read(): Submission {
    const area = this.checked('area') as Area;
    const taskType = this.checked('task_type') as TaskType;
    const taskSecondary = this.taskSecondary();
    const published = this.checked('was_published') || null;

    return {
      title: this.value('title'),
      area,
      // The database refuses an `areaOther` on any area but `other`, so it is dropped here
      // rather than sent and rejected: somebody who typed one and then changed their mind
      // should not have their submission fail on a field that is no longer on their screen.
      areaOther: area === 'other' ? this.value('area_other') : '',
      taskType,
      taskSecondary,
      careerStage: (this.value('career_stage') || '') as CareerStage | '',
      tools: this.readTools(),
      aim: this.value('aim'),
      method: this.value('method'),
      outcome: this.checked('outcome') as Outcome,
      outcomeNotes: this.value('outcome_notes'),
      verification: this.value('verification'),
      prompts: this.value('prompts'),
      transcriptExcerpt: this.value('transcript_excerpt'),
      transcriptUrl: this.value('transcript_url'),
      caveats: this.value('caveats'),
      references: this.readReferences(),
      thirdPartyMaterialConfirmed: this.box('third_party_confirmed'),
      timeSpentMinutes: this.value('time_spent_minutes')
        ? Number(this.value('time_spent_minutes'))
        : null,
      wasPublished: published,
      // The CHECK refuses a disclosure answer without a publication, so this is not
      // defensive: "not published, not disclosed" reads as a failure to disclose and is
      // actually a question that did not apply.
      wasDisclosed: published === 'yes' ? this.tristate('was_disclosed') : null,
      authorConfidence: this.checked('author_confidence')
        ? Number(this.checked('author_confidence'))
        : null,
      ratings: ratingsFor(this.ratingAnswers(), area, taskType, taskSecondary),
      timeSaved: this.checked('time_saved') || null,
      generalises: (this.checked('generalises') ?? '') as Generalises | '',
      // Null is "did not answer", and must stay distinct from false: the radios start
      // unselected for exactly this reason.
      learnedSomething: this.tristate('learned_something'),
      learnedNotes: this.value('learned_notes'),
      tagCodes: this.chosenTags(),
    };
  }

  /** Whether the third-party affirmation is being asked for at all. */
  private needsRights(): boolean {
    return Boolean(this.value('transcript_excerpt') || this.value('prompts'));
  }

  // ── Keeping the form consistent with itself ─────────────────────────────────────────

  /**
   * Everything that depends on an answer somewhere else. Called on every input and change.
   *
   * Each branch exists because the alternative is a form that contradicts a constraint:
   * `area_other` on an area that is not `other`, a disclosure answer with no publication, a
   * novelty score against a question nobody was shown, or a tick affirming something about
   * material that was never pasted.
   */
  sync(): void {
    syncCounters(this.form);
    this.syncAreaOther();
    this.syncTaskSecondary();
    this.syncDisclosure();
    this.syncRights();
    this.syncScales();
    this.syncReferenceWarnings();
    this.renumber();
  }

  private syncAreaOther(): void {
    const show = this.checked('area') === 'other';
    this.areaOther.hidden = !show;
    if (!show) {
      const field = this.form.querySelector<HTMLInputElement>('#area_other');
      if (field) field.value = '';
    }
  }

  /**
   * The primary task cannot also be a secondary one, and three is the cap.
   *
   * Disabled rather than hidden, both times. An option that vanishes when you tick a third
   * looks like a bug; an option that is visibly unavailable shows the shape of the rule.
   */
  private syncTaskSecondary(): void {
    const primary = this.checked('task_type');
    const chosen = this.taskSecondary();
    const atCap = chosen.length >= REPORT_LIMITS.taskSecondary;

    for (const input of this.form.querySelectorAll<HTMLInputElement>(
      'input[name="task_secondary"]',
    )) {
      if (input.value === primary) {
        input.checked = false;
        input.disabled = true;
      } else {
        input.disabled = atCap && !input.checked;
      }
    }
  }

  private syncDisclosure(): void {
    const show = this.checked('was_published') === 'yes';
    this.disclosure.hidden = !show;

    if (!show) {
      const none = this.form.querySelector<HTMLInputElement>('#disclosed-none');
      if (none) none.checked = true;
    }
  }

  private syncRights(): void {
    const show = this.needsRights();
    this.rights.hidden = !show;

    // Not cleared when hidden. Somebody who pastes a transcript, ticks the box, then trims
    // the excerpt to nothing and pastes it back should not have to tick it again — and the
    // submission drops the tick anyway when there is nothing pasted.
    if (!show) setFieldError('third_party_confirmed', null, this.form);
  }

  private syncScales(): void {
    const area = this.checked('area');
    const primary = this.checked('task_type');
    const secondary = this.taskSecondary();

    for (const scale of RATING_SCALES) {
      if (!scale.when) continue;

      const row = this.form.querySelector<HTMLElement>(`[data-scale="${scale.key}"]`);
      if (row) row.hidden = !scaleApplies(scale, area, primary, secondary);
    }
  }

  private syncReferenceWarnings(): void {
    for (const row of this.referenceList.querySelectorAll<HTMLElement>('.tool-row')) {
      const warning = row.querySelector<HTMLElement>('[data-reference-warning]');
      if (!warning) continue;

      const message = referenceWarning(
        {
          kind: row.querySelector<HTMLSelectElement>('[data-reference-kind]')?.value ?? '',
          url: row.querySelector<HTMLInputElement>('[data-reference-url]')?.value ?? '',
        },
        LOGIN_WALLED_HOSTS,
      );

      warning.textContent = message ?? '';
      warning.hidden = message === null;
    }
  }

  /**
   * "Tool 1", "Link 2", in order, after anything is added or removed — and Remove disabled on
   * the last tool row.
   *
   * Without the renumbering, a list that has had its second row removed reads "Tool 1, Tool 3"
   * and the numbers stop being about position, which is the only thing they were for.
   *
   * Remove is disabled rather than hidden, and only on tools: at least one tool is required, so
   * the control genuinely cannot do anything, and a button that silently declines is worse than
   * one that says it cannot. References have no minimum, so theirs stays live down to zero.
   */
  private renumber(): void {
    const label = (list: HTMLElement, word: string): void => {
      [...list.querySelectorAll<HTMLElement>('[data-row-legend]')].forEach((legend, index) => {
        legend.textContent = `${word} ${index + 1}`;
      });
    };

    label(this.toolList, 'Tool');
    label(this.referenceList, 'Link');

    const onlyOne = this.toolList.children.length === 1;
    for (const button of this.toolList.querySelectorAll<HTMLButtonElement>(
      '[data-tool-remove]',
    )) {
      button.disabled = onlyOne;
    }
  }

  // ── Repeaters ───────────────────────────────────────────────────────────────────────

  addTool(values?: SubmissionTool): HTMLElement {
    const row = this.clone(this.toolTemplate);
    this.sequence += 1;

    for (const part of ['name', 'version', 'used-on', 'role'] as const) {
      const selector = part === 'used-on' ? '[data-tool-date]' : `[data-tool-${part}]`;
      this.bind(row, part, `tool-${part}-${this.sequence}`, selector);
    }

    if (values) {
      this.put(row, '[data-tool-name]', values.name);
      this.put(row, '[data-tool-version]', values.version);
      this.put(row, '[data-tool-date]', values.usedOn);
      this.put(row, '[data-tool-role]', values.role);
    }

    row.querySelector<HTMLButtonElement>('[data-tool-remove]')?.addEventListener(
      'click',
      () => {
        // The last row is emptied rather than removed. A section with no fields at all reads
        // as broken, and at least one tool is required in any case.
        if (this.toolList.children.length === 1) {
          for (const input of row.querySelectorAll<HTMLInputElement>('input')) input.value = '';
        } else {
          row.remove();
        }
        this.onChange();
      },
    );

    this.toolList.append(row);
    return row;
  }

  addReference(values?: SubmissionReference): HTMLElement {
    const row = this.clone(this.referenceTemplate);
    this.sequence += 1;

    for (const part of ['kind', 'url'] as const) {
      this.bind(row, part, `reference-${part}-${this.sequence}`, `[data-reference-${part}]`);
    }

    if (values) {
      const kind = row.querySelector<HTMLSelectElement>('[data-reference-kind]');
      if (kind) kind.value = values.kind;
      this.put(row, '[data-reference-url]', values.url);
    }

    row.querySelector<HTMLButtonElement>('[data-reference-remove]')?.addEventListener(
      'click',
      () => {
        // Removed outright, unlike a tool row: nothing here is required, so an empty list is
        // the correct resting state and a blank row left behind would invite filling in.
        row.remove();
        this.onChange();
      },
    );

    this.referenceList.append(row);
    return row;
  }

  private clone(template: HTMLTemplateElement): HTMLElement {
    const fragment = template.content.cloneNode(true) as DocumentFragment;
    return fragment.firstElementChild as HTMLElement;
  }

  /** Give one control in a cloned row a unique id and point its label at it. */
  private bind(row: HTMLElement, part: string, id: string, selector: string): void {
    const label = row.querySelector<HTMLLabelElement>(`[data-label-for="${part}"]`);
    const control = row.querySelector<HTMLElement>(selector);
    if (!label || !control) return;

    control.id = id;
    label.htmlFor = id;
  }

  private put(row: HTMLElement, selector: string, text: string): void {
    const control = row.querySelector<HTMLInputElement>(selector);
    if (control) control.value = text;
  }

  // ── Tags ────────────────────────────────────────────────────────────────────────────

  /**
   * Fetch the vocabulary and build the checkboxes.
   *
   * A failure here is a sentence rather than an empty section, and it says the submission
   * still works: subject areas are optional, and losing them is a far smaller harm than
   * losing the account of the work.
   */
  async fillTags(): Promise<void> {
    const result = await loadTags();

    if (!result.ok) {
      this.tagStatus.textContent =
        'The subject categories could not be loaded. You can carry on without them and they can be added later.';
      return;
    }

    for (const tag of result.value) {
      const option = this.clone(this.tagTemplate) as HTMLLabelElement;
      const input = option.querySelector<HTMLInputElement>('.tag__input');
      if (!input) continue;

      input.value = tag.code;
      input.name = 'tags';
      input.id = `tag-${tag.code}`;
      option.htmlFor = input.id;

      const code = option.querySelector('.tag__code');
      const label = option.querySelector('.tag__label');
      if (code) code.textContent = tag.code;
      if (label) label.textContent = tag.label;
      option.dataset.search = `${tag.code} ${tag.label}`.toLowerCase();

      input.addEventListener('change', () => {
        this.describeTags();
        this.onChange();
      });

      this.tagOptions.append(option);
    }

    this.tagStatus.hidden = true;
    this.tagOptions.hidden = false;

    for (const code of this.pendingTags) {
      const input = this.tagOptions.querySelector<HTMLInputElement>(
        `#${CSS.escape(`tag-${code}`)}`,
      );
      if (input) input.checked = true;
    }
    this.pendingTags = [];

    this.describeTags();
  }

  /** Hold tag codes until the vocabulary has arrived. */
  wantTags(codes: readonly string[]): void {
    this.pendingTags = [...codes];
  }

  private filterTags(): void {
    const needle = this.tagSearch.value.trim().toLowerCase();

    for (const option of this.tagOptions.querySelectorAll<HTMLLabelElement>('.tag')) {
      // A chosen tag stays visible however the search is narrowed. Hiding something
      // somebody has selected is how a form silently loses an answer.
      const chosen = option.querySelector<HTMLInputElement>('.tag__input')?.checked ?? false;
      option.hidden =
        !chosen && needle.length > 0 && !(option.dataset.search ?? '').includes(needle);
    }
  }

  private describeTags(): void {
    const chosen = this.chosenTags();
    this.tagChosen.textContent = chosen.length
      ? `Chosen: ${chosen.join(', ')}`
      : 'No categories chosen.';
  }

  clearTags(): void {
    for (const input of this.tagOptions.querySelectorAll<HTMLInputElement>('.tag__input')) {
      input.checked = false;
    }
    this.describeTags();
  }

  // ── The progress indicator ──────────────────────────────────────────────────────────

  /**
   * Whether a section has an answer. Deliberately generous — this drives a progress
   * indicator, not the submission, and a bar that only moved on a fully valid section would
   * sit at zero while somebody typed.
   */
  private answered(id: string): boolean {
    switch (id) {
      case 'title':
        return Boolean(this.value('title'));
      case 'area':
        return Boolean(this.checked('area'));
      case 'task-type':
        return Boolean(this.checked('task_type'));
      case 'tools':
        return this.readTools().some(
          (tool) => tool.name.trim() && tool.version.trim() && tool.usedOn,
        );
      case 'about-you':
        return Boolean(this.value('career_stage'));
      case 'aim':
        return Boolean(this.value('aim'));
      case 'method':
        return Boolean(this.value('method'));
      case 'outcome':
        return Boolean(this.checked('outcome')) && Boolean(this.value('outcome_notes'));
      case 'verification':
        return Boolean(this.value('verification'));
      case 'prompts':
        return Boolean(this.value('prompts'));
      case 'transcript':
        return Boolean(this.value('transcript_excerpt'));
      case 'caveats':
        return Boolean(this.value('caveats'));
      case 'tags':
        return this.chosenTags().length > 0;
      case 'references':
        return this.readReferences().length > 0;
      case 'learned':
        return (
          Boolean(this.checked('learned_something')) || Boolean(this.value('learned_notes'))
        );
      case 'counting':
        return (
          Boolean(this.value('time_spent_minutes')) ||
          Boolean(this.checked('author_confidence')) ||
          Boolean(this.checked('generalises')) ||
          RATING_SCALES.some((scale) => this.checked(scale.key) !== undefined)
        );
      default:
        return false;
    }
  }

  /** How many of the sections have something in them, and marks each one. */
  markSections(): number {
    let done = 0;

    for (const section of SECTIONS) {
      const element = this.form.querySelector<HTMLElement>(`[data-section="${section.id}"]`);
      if (!element) continue;

      const answered = this.answered(section.id);
      if (answered) done += 1;
      element.toggleAttribute('data-complete', answered);
    }

    return done;
  }

  // ── Validation ──────────────────────────────────────────────────────────────────────

  /**
   * Mark every problem and return the first one to send somebody to.
   *
   * Every failing field is marked rather than just the first, so a person with three
   * problems finds out about all three in one attempt. The database is still the truth —
   * this exists so that the answer arrives before a round trip, not instead of one.
   */
  validate(): FirstProblem {
    const tools = this.readTools();
    const references = this.readReferences();
    let first: FirstProblem = null;

    const note = (id: string): void => {
      if (!first) first = id;
    };

    const problems: { id: string; error: string | null }[] = [
      { id: 'title', error: validateRequiredText(this.value('title'), REPORT_LIMITS.title, 'A title') },
      { id: 'aim', error: validateRequiredText(this.value('aim'), REPORT_LIMITS.aim, 'The aim') },
      { id: 'method', error: validateRequiredText(this.value('method'), REPORT_LIMITS.method, 'The method') },
      { id: 'outcome_notes', error: validateRequiredText(this.value('outcome_notes'), REPORT_LIMITS.outcomeNotes, 'The outcome notes') },
      { id: 'verification', error: validateVerification(this.value('verification'), REPORT_LIMITS.verification) },
      { id: 'prompts', error: validateOptionalText(this.value('prompts'), REPORT_LIMITS.prompts, 'The prompts') },
      { id: 'transcript_excerpt', error: validateOptionalText(this.value('transcript_excerpt'), REPORT_LIMITS.transcriptExcerpt, 'The transcript excerpt') },
      { id: 'transcript_url', error: validateTranscriptUrl(this.value('transcript_url'), REPORT_LIMITS.transcriptUrl) },
      { id: 'caveats', error: validateOptionalText(this.value('caveats'), REPORT_LIMITS.caveats, 'The advice') },
      {
        id: 'learned_notes',
        error:
          validateOptionalText(this.value('learned_notes'), REPORT_LIMITS.learnedNotes, 'The note') ??
          // The rule the database also enforces: a note elaborates on an answer.
          (this.value('learned_notes') && this.tristate('learned_something') === null
            ? 'Answer yes or no first, so the note has something to elaborate on.'
            : null),
      },
      { id: 'time_spent_minutes', error: validateTimeSpent(this.value('time_spent_minutes'), REPORT_LIMITS.timeSpentMinutes) },
      {
        id: 'area_other',
        error:
          this.checked('area') === 'other'
            ? validateRequiredText(this.value('area_other'), REPORT_LIMITS.areaOther, 'A few words about which')
            : null,
      },
    ];

    // The rule the database also enforces: a share link is never the only record.
    if (this.value('transcript_url') && !this.value('transcript_excerpt')) {
      problems.push({
        id: 'transcript_excerpt',
        error:
          'Paste an excerpt as well. Share links expire and get revoked, so a link on its own would leave nothing behind.',
      });
    }

    for (const problem of problems) {
      setFieldError(problem.id, problem.error, this.form);
      if (problem.error) note(problem.id);
    }

    // Choices, which have no Field wrapper and so are marked by hand.
    const groups: [string, string | undefined, string][] = [
      ['area', this.checked('area'), 'Choose the kind of work this was.'],
      ['task_type', this.checked('task_type'), 'Choose what the tool was asked to do.'],
      ['outcome', this.checked('outcome'), 'Say what happened. All three answers are equally welcome.'],
    ];

    for (const [name, answer, message] of groups) {
      const target = this.form.querySelector<HTMLElement>(`#${name}-error`);
      if (!target) continue;

      target.textContent = answer ? '' : message;
      target.hidden = Boolean(answer);
      if (!answer) note(`section-${name.replace('_', '-')}`);
    }

    // The cap the checkboxes already enforce by disabling. Checked anyway, because a
    // restored draft writes `checked` directly and never trips a disable.
    const secondaryError = this.form.querySelector<HTMLElement>('#task_secondary-error');
    const overCap = this.taskSecondary().length > REPORT_LIMITS.taskSecondary;
    if (secondaryError) {
      secondaryError.textContent = overCap
        ? `Choose at most ${REPORT_LIMITS.taskSecondary}. Past that it is the whole list, which says nothing.`
        : '';
      secondaryError.hidden = !overCap;
    }
    if (overCap) note('section-task-type');

    // Asked exactly when there is something pasted to have removed something from.
    if (this.needsRights() && !this.box('third_party_confirmed')) {
      setFieldError(
        'third_party_confirmed',
        "Confirm you have removed other people's unpublished material. Everything here is published for anyone to copy.",
        this.form,
      );
      note('third_party_confirmed');
    }

    // Tool rows, and the message goes on the row it is about.
    //
    // Read from the element rather than by index into `readTools()`. That list drops empty
    // rows, so an empty row in the middle of three would shift every message below it onto
    // the wrong row — which reads as the form complaining about a field that is fine.
    let badRow = false;

    for (const row of this.toolList.querySelectorAll<HTMLElement>('.tool-row')) {
      const target = row.querySelector<HTMLElement>('[data-tool-error]');
      if (!target) continue;

      const tool = this.toolFrom(row);
      const empty = !tool.name.trim() && !tool.version.trim() && !tool.usedOn;

      const message = empty
        ? null
        : validateTool(
            tool,
            {
              name: REPORT_LIMITS.toolName,
              version: REPORT_LIMITS.toolVersion,
              role: REPORT_LIMITS.toolRole,
            },
            EARLIEST_TOOL_USE,
          );

      target.textContent = message ?? '';
      target.hidden = !message;
      if (message) badRow = true;
    }

    if (!tools.length || tools.length > REPORT_LIMITS.tools || badRow) note('section-tools');

    // Reference rows, the same way and for the same reason.
    let badReference = false;

    for (const row of this.referenceList.querySelectorAll<HTMLElement>('.tool-row')) {
      const target = row.querySelector<HTMLElement>('[data-reference-error]');
      if (!target) continue;

      const reference = this.referenceFrom(row);
      const message = reference.url.trim()
        ? validateReference(
            reference,
            { url: REPORT_LIMITS.referenceUrl },
            REFERENCE_KIND_VALUES,
          )
        : null;

      target.textContent = message ?? '';
      target.hidden = !message;
      if (message) badReference = true;
    }

    if (references.length > REPORT_LIMITS.references || badReference) {
      note('section-references');
    }

    return first;
  }

  /** The message for a tool-count problem, which is a section-level rather than a row-level
   *  failure and so has nowhere of its own to be shown. */
  toolCountMessage(): string | null {
    const count = this.readTools().length;

    if (count === 0) {
      return 'Record at least one tool, with its version and the date you used it. The date is what lets a listing show later that an account has gone stale.';
    }
    if (count > REPORT_LIMITS.tools) {
      return `${REPORT_LIMITS.tools} tools is the most one account of a session can usefully describe. A second session is a second report.`;
    }

    return null;
  }

  // ── Pre-filling ─────────────────────────────────────────────────────────────────────

  /** Put an existing report into the form, for the edit screen. */
  prefill(report: EditableReportForEdit): void {
    const set = (id: string, text: string): void => {
      const control = this.form.querySelector<HTMLInputElement | HTMLTextAreaElement>(
        `#${CSS.escape(id)}`,
      );
      if (control) control.value = text;
    };

    set('title', report.title);
    set('area_other', report.areaOther ?? '');
    set('aim', report.aim);
    set('method', report.method);
    set('outcome_notes', report.outcomeNotes);
    set('verification', report.verification);
    set('prompts', report.prompts ?? '');
    set('transcript_excerpt', report.transcriptExcerpt ?? '');
    set('transcript_url', report.transcriptUrl ?? '');
    set('caveats', report.caveats ?? '');
    set('learned_notes', report.learnedNotes ?? '');
    set('career_stage', report.careerStage ?? '');
    if (report.timeSpentMinutes !== null) {
      set('time_spent_minutes', String(report.timeSpentMinutes));
    }

    this.pick('area', report.area);
    this.pick('task_type', report.taskType);
    this.pick('outcome', report.outcome);
    this.pick('generalises', report.generalises ?? '');
    if (report.learnedSomething !== null) {
      this.pick('learned_something', report.learnedSomething ? 'yes' : 'no');
    }

    for (const task of report.taskSecondary) {
      const input = this.form.querySelector<HTMLInputElement>(
        `input[name="task_secondary"][value="${CSS.escape(task)}"]`,
      );
      if (input) input.checked = true;
    }

    this.pick('was_published', report.wasPublished ?? '');

    if (report.wasPublished === 'yes') {
      this.pick(
        'was_disclosed',
        report.wasDisclosed === true ? 'yes' : report.wasDisclosed === false ? 'no' : '',
      );
    }

    if (report.authorConfidence !== null) {
      this.pick('author_confidence', String(report.authorConfidence));
    }

    for (const scale of RATING_SCALES) {
      const answer = report.ratings[scale.key];
      if (answer !== null) this.pick(scale.key, String(answer));
    }

    this.pick('time_saved', report.timeSaved ?? '');
    this.tick('third_party_confirmed', report.thirdPartyMaterialConfirmed);

    for (const tool of report.tools) {
      this.addTool({
        name: tool.name,
        version: tool.version,
        usedOn: tool.usedOn,
        role: tool.role ?? '',
      });
    }
    if (report.tools.length === 0) this.addTool();

    for (const reference of report.references) {
      this.addReference({
        kind: reference.kind,
        url: reference.url,
      });
    }

    this.wantTags(report.tagCodes);
  }

  private pick(name: string, value: string): void {
    const input = this.form.querySelector<HTMLInputElement>(
      `input[name="${CSS.escape(name)}"][value="${CSS.escape(value)}"]`,
    );
    if (input) input.checked = true;
  }

  private tick(id: string, on: boolean): void {
    const input = this.form.querySelector<HTMLInputElement>(`#${CSS.escape(id)}`);
    if (input) input.checked = on;
  }

  /** Empty every repeater and start again with one tool row. Used by "discard draft". */
  resetRepeaters(): void {
    this.toolList.replaceChildren();
    this.referenceList.replaceChildren();
    this.addTool();
  }
}
