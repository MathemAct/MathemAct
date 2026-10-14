/**
 * The small amount of DOM work every account form does: showing a message, marking a
 * field, and putting a button into its waiting state.
 *
 * There is no framework here and there should not be. Eight forms with one text input and
 * a button each do not justify shipping a renderer to an audience that came to read, and
 * the whole site is static files. What they do justify is doing the accessible parts once,
 * correctly, in one place — because the failure mode of hand-written form JavaScript is
 * always the same, an error that appears on screen and is never announced.
 */

/**
 * Find an element that the markup alongside this script is known to contain. Throws when
 * it is missing, because that is a mistake in a page rather than a condition to handle:
 * the selector and the element it looks for are written in the same file, and a silent
 * null here surfaces much later as a button that does nothing.
 */
export function query<T extends Element>(selector: string, root: ParentNode = document): T {
  const found = root.querySelector<T>(selector);
  if (!found) throw new Error(`No element matches ${selector}`);
  return found;
}

export type StatusKind = 'error' | 'success' | 'notice';

/**
 * Show the form-level message.
 *
 * Focus moves to the message on an error. Announcing it through the live region alone is
 * not enough: a live region is easy to miss, it says nothing about where to go next, and a
 * sighted keyboard user gets nothing from it at all. Moving focus puts the explanation and
 * the tab position in the same place, which is what someone who just pressed a button that
 * did not work is looking for.
 */
export function showStatus(
  element: HTMLElement,
  kind: StatusKind,
  message: string | readonly string[],
): void {
  const lines = typeof message === 'string' ? [message] : message;

  element.replaceChildren(
    ...lines.map((line) => {
      const p = document.createElement('p');
      p.textContent = line;
      return p;
    }),
  );

  element.classList.remove('form-status--success', 'form-status--notice');
  if (kind !== 'error') element.classList.add(`form-status--${kind}`);
  element.hidden = false;

  if (kind === 'error') element.focus();
}

export function hideStatus(element: HTMLElement): void {
  element.hidden = true;
  element.replaceChildren();
}

/**
 * Attach or clear the message under one field, and mark the control itself.
 *
 * `aria-invalid` and the message are set together so the two can never disagree. The
 * message element is referenced from the control by `aria-describedby` in Field.astro, so
 * it is read out when the field takes focus rather than only when it appears.
 */
export function setFieldError(id: string, message: string | null, root: ParentNode = document): void {
  const control = root.querySelector<HTMLElement>(`#${CSS.escape(id)}`);
  const error = root.querySelector<HTMLElement>(`#${CSS.escape(id)}-error`);
  if (!control || !error) return;

  if (message) {
    control.setAttribute('aria-invalid', 'true');
    error.textContent = message;
    error.hidden = false;
  } else {
    control.removeAttribute('aria-invalid');
    error.textContent = '';
    error.hidden = true;
  }
}

/** Clear every field message in a form. Called at the start of each submission, so a
 *  message from the previous attempt cannot linger next to a field that is now fine. */
export function clearFieldErrors(root: ParentNode): void {
  for (const error of root.querySelectorAll<HTMLElement>('.field__error')) {
    error.textContent = '';
    error.hidden = true;
  }

  for (const control of root.querySelectorAll<HTMLElement>('[aria-invalid]')) {
    control.removeAttribute('aria-invalid');
  }
}

/**
 * Put a submit button into its waiting state and back again.
 *
 * The label changes to the present participle of what is happening — "Creating account…"
 * — rather than a spinner or a generic "Please wait". Signup involves an email being sent
 * and can take a couple of seconds on a bad connection, which is long enough for someone
 * to conclude nothing happened and press it again.
 */
export function setBusy(button: HTMLButtonElement, busy: boolean, busyLabel?: string): void {
  if (busy) {
    button.dataset.idleLabel ??= button.textContent ?? '';
    if (busyLabel) button.textContent = busyLabel;
    button.disabled = true;
  } else {
    if (button.dataset.idleLabel) button.textContent = button.dataset.idleLabel;
    button.disabled = false;
  }
}

/**
 * Run the first validator that fails and attach its message to the field it belongs to.
 * Returns true when everything passed.
 *
 * Every failing field is marked, not just the first, so somebody with three problems finds
 * out about all three in one attempt rather than three.
 */
export function validateFields(
  checks: readonly { id: string; error: string | null }[],
  root: ParentNode = document,
): boolean {
  let valid = true;

  for (const check of checks) {
    setFieldError(check.id, check.error, root);
    if (check.error) valid = false;
  }

  if (!valid) {
    const first = checks.find((check) => check.error);
    if (first) root.querySelector<HTMLElement>(`#${CSS.escape(first.id)}`)?.focus();
  }

  return valid;
}

/**
 * Update every character counter in `root` from the field it names.
 *
 * The counter markup comes from Field.astro's `counter` prop, which renders the element
 * and the cap but cannot animate it — a component has no script of its own here. So the
 * markup is inert until something calls this, and a page that renders a counter and never
 * wires it ships a field that reads `0 / 200` however much is typed into it. That shipped
 * on /opinions/new/ and /network/new/: the prop looked like the whole feature.
 */
export function syncCounters(root: ParentNode = document): void {
  for (const counter of root.querySelectorAll<HTMLElement>('[data-counter-for]')) {
    const field = root.querySelector<HTMLInputElement | HTMLTextAreaElement>(
      `#${CSS.escape(counter.dataset.counterFor!)}`,
    );
    if (!field) continue;

    const max = Number(counter.dataset.max);
    const used = field.value.length;

    counter.querySelector('[data-counter-value]')!.textContent = String(used);
    if (used > max * 0.9) counter.setAttribute('data-near', '');
    else counter.removeAttribute('data-near');
  }
}

/**
 * Wire every counter in a form and keep it current: one initial sync, then on input and
 * on change.
 *
 * The initial sync matters for a form rendered with values in it, and for the browser
 * restoring what somebody had typed before navigating away — neither fires an input event.
 * `reset` is deferred, because the event fires *before* the controls are cleared and
 * counting them at that point just re-reads the values that are about to go.
 *
 * A form that already drives counters from a wider refresh — the report form recomputes a
 * progress indicator on the same keystroke — should call `syncCounters` from there instead
 * of adding a second pair of listeners.
 */
export function wireCounters(form: HTMLFormElement): void {
  const sync = (): void => syncCounters(form);

  sync();
  form.addEventListener('input', sync);
  form.addEventListener('change', sync);
  form.addEventListener('reset', () => window.setTimeout(sync, 0));
}
