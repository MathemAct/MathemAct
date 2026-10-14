# Sources for legal and governance pages

Every factual claim on the privacy, terms, licence, and accessibility pages is listed
here with its primary source URL and the date it was accessed. Claims derived from a
secondary source rather than a primary one are flagged.

All accessed **16 August 2026**.

---

## Supabase

**EU-region data storage (AWS)**
URL: https://supabase.com/docs/guides/platform/regions
The EU regions listed run on AWS infrastructure. "Central EU (Frankfurt)" may not be
pinned to eu-central-1.

**Sub-processor list**
URL: https://supabase.com/legal/customer-resources/subprocessor-list
PDF version: https://supabase.com/legal/subprocessor-list/June-1-2026.pdf
20 sub-processors listed as of June 2026; includes Amazon Web Services, Cloudflare,
GitHub, Google, Vercel. Supabase gives 30 days' notice of changes.

**DPA (Data Processing Agreement)**
URL: https://supabase.com/legal/dpa
Version dated August 1, 2026. Incorporates Standard Contractual Clauses (Module Two,
controller-to-processor), UK Addendum, and Swiss DPA compliance.

**Free-tier pausing**
URL: https://supabase.com/docs/guides/platform/going-into-prod
Projects pause after 7 days of inactivity (no API requests, DB queries, or Edge Function
invocations). Pausing preserves all data but makes it inaccessible.

**Project deletion**
URL: https://supabase.com/docs/guides/platform/delete-project
"Deleting a Supabase project is a permanent and irreversible action."
"We cannot recover deleted projects."
Free tier: zero days of backup retention.

**Privacy policy**
URL: https://supabase.com/privacy

---

## Brevo

**Data storage location**
URL (returned HTTP 403, accessed via search result snippets):
https://help.brevo.com/hc/en-us/articles/360001005510
FLAG: Not directly fetched. Search snippets indicate EU-only storage (France/Germany on OVH
infrastructure; Google Cloud, Belgium region). Verify from a logged-in Brevo account.

**DPA**
URL: https://corp-backend.brevo.com/wp-content/uploads/2024/08/BREVO-Annex-2-DPA-150524.pdf
Annex 2 DPA dated August 2024. Governing law: French law.

**Privacy policy**
URL: https://www.brevo.com/legal/privacypolicy/

**Transactional email log retention**
URL (returned HTTP 403, accessed via search snippets):
https://help.brevo.com/hc/en-us/articles/4415743225746
FLAG: Not directly fetched. Search snippets indicate indefinite retention by default for
accounts below 10M events; up to 24 months maximum for high-volume accounts.

---

## Cloudflare Turnstile

**Turnstile Privacy Addendum**
URL: https://www.cloudflare.com/turnstile-privacy-policy/
Last updated: June 18, 2025
What Turnstile collects: "client IP address, TLS Fingerprint, User-Agent Header and
Sitekey and associated origin". Cloudflare is a data controller for the purpose of
improving bot detection (legitimate interests).
Requirement: websites using Turnstile must reference this addendum in their privacy policy.

**Pre-clearance cookie**
URL: https://developers.cloudflare.com/turnstile/
Turnstile can issue a "Pre-clearance" cookie in SPA scenarios. The Addendum does not
state explicitly that "no cookies are set" — it defers to Cloudflare's Cookie Policy.
FLAG: Claims that Turnstile sets "no cookies" found in competitor documentation, not in
Cloudflare's own language. This page does not reproduce that claim.

**Cloudflare Cookie Policy**
URL: https://www.cloudflare.com/cookie-policy/

**Cloudflare Privacy Policy**
URL: https://www.cloudflare.com/privacypolicy/

---

## GitHub Pages

**IP logging statement**
URL: https://docs.github.com/en/pages/getting-started-with-github-pages/about-github-pages
Exact quote: "When a GitHub Pages site is visited, the visitor's IP address is logged and
stored for security purposes, regardless of whether the visitor has signed into GitHub or
not."

**GitHub General Privacy Statement**
URL: https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement
Effective date: April 27, 2026.

**GitHub Terms of Service**
URL: https://docs.github.com/en/site-policy/github-terms/github-terms-of-service
Effective date: April 27, 2026.

---

## Creative Commons BY 4.0

**Licence deed**
URL: https://creativecommons.org/licenses/by/4.0/deed.en

**Legal code**
URL: https://creativecommons.org/licenses/by/4.0/legalcode.en
Attribution requirements (Section 3(a)): creator identification, copyright notice,
warranty disclaimer, URI/hyperlink to the material, licence notice, and modification
indication. Attribution may be met "in any reasonable manner based on the medium, means,
and context".

**Recommended attribution practice**
URL: https://wiki.creativecommons.org/wiki/Recommended_reports_for_attribution
Format: Title — Author — Source URL — Licence name + link.

Commercial use: permitted. Derivative works: permitted. Relicensing derivatives: permitted.

---

## ROR (Research Organization Registry)

**Terms of use and licence**
URL: https://ror.org/terms-of-use/
Licence: Creative Commons CC0 1.0 Universal Public Domain Dedication.
Exact quote: "All ROR IDs and metadata are provided under the Creative Commons CC0 1.0
Universal Public Domain Dedication. There are no restrictions on access to and use of ROR
IDs and metadata."
Note: ROR website content is CC BY 4.0; ROR logos are CC BY-ND 4.0; source code is MIT.

**GeoNames attribution for location data**
FLAG: Earlier search results claimed a CC BY attribution requirement for GeoNames data
used by ROR. This claim does not appear on the ROR Terms of Use page. Not reproduced in
the licence page pending direct verification.

---

## GDPR

**Primary legislation**
URL: https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32016R0679
Regulation (EU) 2016/679.

**Article 13 text** (information to be provided where data collected from the subject)
Verified via: https://gdpr-info.eu/art-13-gdpr/
Requirements summarised in docs/decisions.md.

**Article 14 text** (information where data not obtained from the subject)
Verified via: https://gdpr-info.eu/art-14-gdpr/

---

## Garante per la protezione dei dati personali (Italy)

**Official website**
URL: https://www.garanteprivacy.it

**Current postal address**
Piazza Venezia 11, 00187 Roma, Italy.
Note: The Garante moved from Piazza di Monte Citorio 121 to this address in 2018. Older
sources may still list the former address.

**Complaints page**
URL: https://www.garanteprivacy.it/diritti/come-agire-per-tutelare-i-tuoi-dati-personali/reclamo
Complaints may be submitted by PEC (protocollo@pec.gpdp.it) or registered post. No
web form exists. Complaints must cite Art. 77 of Regulation (EU) 2016/679.

---

## IBM Plex font

**Licence**
The IBM Plex font family is licensed under the SIL Open Font Licence 1.1.
URL: https://github.com/IBM/plex/blob/master/LICENSE.txt
No attribution requirement for self-hosted use in a website.
