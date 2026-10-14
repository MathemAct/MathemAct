/**
 * Site-wide constants: the things that appear in more than one place and must not drift
 * between them.
 *
 * Navigation lives here rather than inside the layout so that adding a section is one
 * edit, and so the set of real destinations is auditable at a glance. Nothing goes in
 * these lists until the page it points at exists — a nav link to a 404 costs more trust
 * than a short nav does.
 */

export const SITE = {
  name: 'MathemAct',
  mission: 'Collectively shaping the future of mathematical research in the age of AI.',
  description:
    'Structured, first-hand accounts of how AI tools are actually used in mathematical ' +
    'work, and a record of where the community agrees and disagrees about how they ' +
    'should be used.',
  contactEmail: 'matesimpatica@gmail.com',
  /**
   * The address confirmation and password-reset emails arrive from. Named on the
   * confirmation-pending page so an unexpected message is recognisable rather than
   * suspicious — an unfamiliar sender is the single most common reason a confirmation
   * email is deleted or reported.
   *
   * The mail itself is sent by Supabase through Brevo, and the sender is configured in the
   * Supabase dashboard under Authentication → SMTP settings. This constant must be kept in
   * step with that field by hand; nothing checks it. See docs/auth.md.
   */
  senderEmail: 'matesimpatica@gmail.com',
  senderName: 'MathemAct',
  repository: 'https://github.com/MathemAct/MathemAct',
} as const;

export const LICENCE = {
  name: 'CC BY 4.0',
  fullName: 'Creative Commons Attribution 4.0 International',
  url: 'https://creativecommons.org/licenses/by/4.0/',
} as const;

/**
 * The Leiden Declaration on AI and Mathematics supplies the principles this project
 * works under. MathemAct is an independent response to it and carries no endorsement
 * from its authors or from the International Mathematical Union. Any copy referring to
 * the Declaration must keep that distinction explicit.
 */
export const LEIDEN = {
  name: 'Leiden Declaration on Artificial Intelligence and Mathematics',
  shortName: 'Leiden Declaration',
  url: 'https://leidendeclaration.ai/',
  published: 'June 2026',
  /** Verbatim, from the Declaration. Quoted on the home page and the about page — do not
   *  paraphrase these into the quotation marks. */
  quotes: {
    disclosure: "Include a 'Tool and computational resource disclosure' section in your papers",
    evolving: 'though the precise form of such a section will necessarily evolve, we encourage authors to live up to the spirit',
  },
} as const;

export interface NavLink {
  readonly label: string;
  readonly href: string;
}

/** Header navigation. Grows as sections ship. Reports comes first because it is what the
 *  site is for; About explains it to someone who has already seen one. */
export const NAV: readonly NavLink[] = [
  { label: 'Reports', href: '/reports/' },
  { label: 'Opinions', href: '/opinions/' },
  { label: 'Network', href: '/network/' },
  { label: 'About', href: '/about/' },
];

/** Footer navigation, internal pages only. The four main sections live in the header nav
 *  and are intentionally omitted here to avoid repetition. The licence and contact are
 *  rendered separately because one is an external link and the other is a mailto. */
export const FOOTER_NAV: readonly NavLink[] = [
  { label: 'Code of conduct', href: '/code-of-conduct/' },
  { label: 'Privacy', href: '/privacy/' },
  { label: 'Terms', href: '/terms/' },
  { label: 'Licence', href: '/licence/' },
  { label: 'Accessibility', href: '/accessibility/' },
];
