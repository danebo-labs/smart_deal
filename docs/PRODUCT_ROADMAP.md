# Product roadmap

**Current stage:** MVP / MVO demos and pilot discovery.  
**Primary channel:** authenticated web application.  
**Updated:** 2026-07-22.

This roadmap separates what Danebo demonstrates today from capabilities that
must first be validated through sales conversations and pilot usage. It is not
an implementation commitment or a license to introduce speculative
architecture.

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

## Commercial positioning

Safe MVP wording:

> Danebo delivers a traceable visual diagnosis by account, technician, session,
> and request. Persistent conversation history and photographic diagnostic
> records are the next extension for customers that require audit, warranty, or
> before/after evidence.

Do not claim that the MVP retains the original photo or provides an auditable
photographic history.

## Deliberate MVP non-goals

- A generic evidence-management subsystem.
- Work-order management.
- A photographic gallery.
- Automatic indexing of technician photos.
- Automatic conversion of a diagnosis into organizational knowledge.
- Long-term image retention without a validated tenant policy.
