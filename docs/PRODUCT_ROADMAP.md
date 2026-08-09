# Product roadmap

**Current stage:** MVP / MVO demos and pilot discovery.  
**Primary channel:** authenticated web application.  
**Primary field interface (from 2026-09):** voice.  
**Updated:** 2026-08-07.

This roadmap separates what Danebo demonstrates today from capabilities that
must first be validated through sales conversations and pilot usage. It is not
an implementation commitment or a license to introduce speculative
architecture.

Planning documents that this roadmap serves:
[PLAN_GENERAL_2026-08-07.md](PLAN_GENERAL_2026-08-07.md) (strategy),
[PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) (the build month),
[PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md) (billing
unit per segment).

## Thesis correction (2026-08-06): the channel was the problem

Eight discovery interviews converged on a finding that reorders this roadmap:
**a correct answer is not enough — it has to be easier than the current
method.** A certifier tried an AI tool with forms and photos, took longer than
with pencil and paper, and went back to paper. Two other interviewees mentioned
gloves without being asked. Two more already have a Drive folder and `Ctrl+P`.

Multi-brand documentary knowledge was never the missing piece. The missing
piece was an interaction channel compatible with real field conditions: hands
occupied, gloves, grease, poor light, time pressure. **Voice is not an
additional feature; it is the interface that makes what RAG already knows
usable.**

Consequence for this document: voice moves out of "stretch goal" and becomes
the central deliverable of September 2026. Everything in the MVP section below
remains valid as the retrieval and traceability substrate underneath it.

## Current MVP: prove the operational loop

The current offer must demonstrate a short, credible field workflow:

1. A technician asks a question or takes a field photo from the web app.
2. Danebo returns one concise answer with uncertainty made explicit.
3. Indexed manuals remain the source of operational knowledge.
4. Usage, latency, cost, account, user, session, and correlation identifiers
   provide pilot traceability.
5. A pinned document with a known table of contents resolves as a
   deterministic summary (chapter/section list) at zero Bedrock cost, instead
   of falling through to model disambiguation or RAG generation.

### Field-photo contract

- A technician's live photo is used for visual recognition and diagnosis.
- It is **not** automatically knowledge, a `KbDocument`, or a Bedrock Knowledge
  Base source.
- **Override (2026-07-27, explicitly authorized):** the original photo bytes
  are retained in S3 under `field_photos/<account_id>/<sha256>/original.<ext>`,
  plus an 88px thumbnail stored inline on the `field_photos` row, for
  `FIELD_PHOTO_RETENTION_DAYS` (default 90) days so a technician can re-ask
  about the same photo without re-uploading after the 24h diagnosis-cache TTL
  expires. This does **not** change the rest of the contract: the photo is
  still never a `KbDocument` or a Bedrock Knowledge Base source, there is no
  photo gallery, no persistent conversation history, and no "diagnostic
  record" — `field_photos` is bounded retention for re-ask reuse only, not the
  diagnostic-record capability described in the next stage below.
- A compact `[FOTO]` result may remain in the current conversation as temporary
  context for an explicit follow-up question.
- A diagnosis may be reused while account, normalized image SHA-256, locale and
  diagnostic contract version all match and the cache TTL is active. It is
  reprocessed when any of those inputs changes, after expiry, when confidence
  or safety policy requires it, or when a future explicit re-analysis feature
  requests it.
- The photo analysis is the final response to the upload. Danebo must not
  silently resend the same question to RAG after analysis.
- A later, explicit question may correlate a visible component or code with an
  indexed manual.

### What the MVP should measure

- Photo-analysis usage by account and user.
- Successful analyses, failures, latency, and variable model cost.
- Identification versus `UNKNOWN` outcomes when available.
- Whether technicians ask a manual question after a photo analysis.
- Cache hit rate, real visual calls avoided and estimated cost avoided, always
  separated from real provider cost.
- Evidence-present rate, `DATA_NOT_AVAILABLE`, field-verification markers and
  fast reformulations as product-quality signals.
- Time-to-resolution, first-interaction resolution, avoided escalation/revisit,
  confidence change and perceived helpfulness through a short field survey;
  these commercial outcomes cannot be inferred safely from token activity.
- Qualitative buyer demand for photographic retention, work-order linkage,
  before/after evidence, warranty evidence, or installed-part records.

The product should not retain raw photos merely to create a possible future use
case. Repeated buyer demand is the gate for that investment.

## Voice: two artifacts, one shared capture layer

Two distinct field artifacts sit on the same RAG and traceability substrate.
They cannot be sold to the same customer for the same job: by Chilean law a
maintainer cannot certify and a certifier cannot maintain, so there is no
conflict of interest between them.

| | Certifier | Maintainer |
|---|---|---|
| Interaction | Dictation in the field, item by item, photo attached | Hands-free conversation about what the technician is looking at |
| Output | A report draft the certifier reviews, corrects and signs | A spoken answer plus traceability of what was consulted |
| Corpus | Chilean technical standards — bounded, five documents | Manufacturer manuals — hundreds of pages across dozens of brands |
| Needs persistence | **Yes.** See the bounded exception below | No. A rolling session is sufficient |
| Billing unit | Per generated report | Per managed unit of equipment |

**The capture layer is built once.** Speech-to-text plus visible, editable
transcription confirmation is shared by both artifacts. What differs is what
sits on top: the certifier needs a persistent draft, report structure and an
export; the maintainer needs none of those.

### Transcription contract (non-negotiable gate)

- The recognized text is **always** visible and editable before the query or
  the dictated finding is submitted.
- No voice capability ships that sends audio straight to generation without the
  user seeing and being able to correct the text first.
- This matters most for brand names, model numbers and error codes, where an
  uncorrected transcription error produces a technically wrong answer that
  carries the appearance of authority.

### Certifier module red lines

- Danebo **transcribes and structures** what an authorized certifier dictates:
  finding, inspection item, location, photo, and the standard reference the
  certifier himself identifies.
- Danebo does **not** evaluate compliance, does not classify severity, does not
  decide whether equipment passes or fails, and does not sign anything.
- The applicable standard is derived deterministically in Rails from the
  building's final municipal reception date. That is a calendar rule, not a
  technical judgement — it saves a model call and removes any possibility of
  hallucinating a standard. Presenting the applicable standard is a documentary
  aid; it is not an assessment of compliance against it.
- Every exported document is watermarked as a **draft** while it is inside
  Danebo. The signature and the professional judgement are and remain the
  certifier's.
- Capture is free-form dictation and structure is applied afterwards. No long
  forms, and no forcing classification during the inspection itself — that is
  precisely what made the previously abandoned tool slower than paper.

### What voice must measure

- Voice adoption: voice queries over total queries. This is the metric that
  validates or refutes the thesis above.
- Transcription correction rate on brand names, model numbers and error codes.
- Cost per minute of audio, kept separate from cost per text query: minutes of
  audio are a different economic driver than tokens of a single question, and
  the current cost model does not cover them.
- Draft resumption: whether a dictation interrupted in the field is actually
  recovered and completed.

## Next stage: persistent conversations and diagnostic records

This stage begins only after the MVP validates demand for historical operational
records. It should be designed together, rather than adding an isolated photo
archive during the MVP.

Expected scope:

- Multiple distinct conversations per account and user.
- Complete, navigable conversation history with appropriate retention.
- A dedicated diagnostic record associated with its conversation, account, and
  technician.
- Optional private photographic evidence governed by tenant retention and
  authorization policy.
- Simple diagnostic purposes such as diagnosis, before replacement, replacement
  part, and after replacement.
- Optional linkage to an asset, service visit, or external work-order reference
  when a customer workflow requires it.

A diagnostic record is operational evidence. It remains separate from
`KbDocument` and the indexed knowledge base. Any future promotion of field
evidence into organizational knowledge requires an explicit, reviewed workflow.

### Bounded exception (2026-09): the persistent report draft

One narrow slice of this stage is pulled forward, and the exception is recorded
here so it does not become a precedent.

**What is built:** a new persistent model for the certifier's report draft —
findings ordered by inspection item and location, associated photo, the standard
reference the certifier cites, and a state (in progress / ready for review /
sent). Plus a minimal "my reports" list: the certifier's own drafts, by date,
with a resume action. Account-scoped isolation and deletion.

**Why it is not a discretionary pull-forward:** it is a technical prerequisite
of field dictation. `ConversationSession` is a single rolling session per user —
`find_or_create_for` looks it up by `account_id + identifier + channel`, keeps at
most `MAX_HISTORY` (20) messages, and self-destructs after `EXPIRY_DURATION`
(30 days) of inactivity. That is working memory for RAG and is correct for that
purpose. A 15–20 minute certification dictation is a different object: the
certifier must be able to pause, resume, review and correct it before signing.
Under the current model an incoming call, a lost signal in the pit, or simply
closing the app mid-item destroys the work with no recovery.

**What this exception does not authorize:**

- `ConversationSession` is **not modified**. It stays exactly as it is for its
  current purpose; it is a latency-sensitive hot path and must not accumulate
  new complexity.
- The **generic** conversation-history browser for maintainers is not built.
- The **diagnostic record** is not built.

Both of those remain gated on validated demand, designed together, exactly as
this section already required. The slice above is deliberately smaller than that
backlog item: it resolves the dictation prerequisite and nothing else.

## Commercial positioning

Safe MVP wording:

> Danebo delivers a traceable visual diagnosis by account, technician, session,
> and request. Persistent conversation history and photographic diagnostic
> records are the next extension for customers that require audit, warranty, or
> before/after evidence.

Safe product wording once voice ships:

> Danebo is a technical field assistant operated by voice. It consults manuals,
> dictates findings and produces reports with traceable sources, without
> replacing the judgement of the authorized technician, maintainer or certifier.

Safe certifier-module wording:

> Danebo transcribes and organizes the certifier's dictation into a report draft
> with associated photographic evidence. The certifier reviews, corrects and
> signs. Danebo does not evaluate compliance and does not determine approval.

Do not claim that the MVP retains the original photo or provides an auditable
photographic history. Do not claim the product guarantees accuracy, never
hallucinates, or never loses context: absolute claims contradict the calibrated
honesty of the rest of the positioning, and a single live counterexample in a
demo destroys more trust than the comparison with a free general-purpose
assistant ever risked.

## Deliberate MVP non-goals

- A generic evidence-management subsystem.
- Work-order management.
- A photographic gallery.
- Automatic indexing of technician photos.
- Automatic conversion of a diagnosis into organizational knowledge.
- Long-term image retention without a validated tenant policy.
- **A building-administrator module.** Registered as an idea, not as work. The
  certifier model has to be validated first, and the antecedent is discouraging:
  Orona's building-facing app failed with building committees.
- **Any voice capability that skips the transcription contract.**
- **Server-side PDF generation** before a real certifier asks for a file to
  attach to the Carpeta Cero. The first version is an HTML view with a print
  stylesheet: no new dependency, no server cost, and nothing wasted when the
  format changes after the first real review.
- **Compliance evaluation of any kind.** Deriving the applicable standard from a
  date is a documentary aid; judging conformity against it is the certifier's
  legal responsibility and is outside the product boundary.
