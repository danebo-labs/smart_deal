# Web home UI (KB list, chat, lightbox)

Mobile-first layout for field technicians.

---

## Web home: responsive layout, KB card, and lightbox

### Layout (mobile-first)

- **Grid:** `home/index.html.erb` uses a responsive grid; **`data-controller="rag-chat"`** wraps the chat column **and** the desktop sidebar so KB rows use the same Stimulus actions as mobile.
- **Breakpoints:** default = phone; **`sm:`** restores the single-row chat
  input; **`lg:`** shows the desktop sidebar KB card (mobile uses the in-chat
  `mobile-docs-panel` strip, `md:hidden`). The internal usage footer is rendered
  only with `SHOW_USAGE_METRICS=true`.
- **Chat input:** column layout on small screens (textarea full width, then attach + send); desktop keeps inline clip + textarea + send.

### Unified KB card, pagination, refresh

| Piece | Role |
|-------|------|
| `_kb_docs_card.html.erb` | Shared shell for **`:desktop`** (rounded card + scroll) and **`:mobile`** (strip inside `_chat_box`); renders `_kb_docs_card_rows` + optional sentinel. Desktop header uses `account_branding` (logo + optional Danebo wordmark). See [ACCOUNT_BRANDING.md](ACCOUNT_BRANDING.md). |
| `_kb_docs_card_rows.html.erb` | Rows only — reused by initial HTML and Turbo Stream fragments. |
| `_kb_docs_card_sentinel.html.erb` | 1px **IntersectionObserver** target; `docs_scroll_controller.js` fetches `/home/documents_page?page=N` as Turbo Stream. |
| `HomeController` | `PAGE_SIZE` **20**; `#documents` replaces both item containers + sentinels after indexing; `#documents_page` **appends** next page to desktop and mobile. |
| `rag_chat_controller.js` | Subscribes to `KbSyncChannel`; typing-dots loading bubble, 15s nudge, 90s stall hint (both upload and text-query flows); `refreshDocuments()` after **indexed** / **failed**. |

### Live field-photo diagnosis

- JPEG/PNG attachments are analyzed asynchronously by
  `FieldPhotoAnalysisJob` and return `photo_analyzed` over `KbSyncChannel`.
- The photo is diagnostic input, not an indexed document; the KB list is not
  refreshed and no `KbDocument` is created.
- MVP-required behavior is one final visual response per upload. The frontend
  no longer resends the photo question to RAG; manual correlation requires a
  later, explicit question from the technician.
- `/rag/ask` returns a `photo:<uuid>` correlation ID. Only the browser that has
  that exact request pending renders its `photo_analyzed` or photo failure
  event; other users and tabs on the same account ignore it.
- The normalized image crosses the web/worker boundary through a short-lived
  Solid Cache entry, never through Solid Queue arguments. The job deletes the
  temporary entry on success, expiry, cache hit, or failure.
- Diagnoses are cached by contract version, account, normalized SHA-256 and
  locale. Identical bytes in another account are always a miss.

### Thumbnails & full-size lightbox

| Piece | Role |
|-------|------|
| `KbDocumentThumbnail` | 88px JPEG BLOB; inlined as `data:` URL in rows for zero extra round-trip. Created after upload via **`ImageCompressionService`** → Solid Cache key `kb_thumb:*` → **`BedrockIngestionJob`**; backfill: `bin/rake kb:thumbnails:backfill`. |
| `KbDocumentImageUrlService` | Presigned S3 GET for full-size image in the lightbox (`call` / `call_many`). |
| `image_lightbox_controller.js` | Singleton overlay, blur-up from thumb, ESC / backdrop / swipe / back. |
| `application.css` | `.image-lightbox-*` layout (safe areas, 44px close, mobile contain vs desktop natural size). |
| `config/locales/*.yml` | `home.lightbox.*` |

**Environment / IAM:** `KNOWLEDGE_BASE_S3_BUCKET`, region, AWS credentials; app role needs **`s3:GetObject`** for presigned URLs.

**Tests (non-exhaustive):** `test/services/kb_document_image_url_service_test.rb`, `test/controllers/home_controller_test.rb` (pagination, sentinels, dual-stream `documents`, thumbnails).

## Web workspace: pinned KB documents & Bedrock retrieval

| Piece | Role |
|-------|------|
| `ConversationSession` | `EXPIRY_DURATION` (30 days, sliding via `refresh!` on pin/unpin flows). `pin_kb_document!` / `unpin_kb_document!` maintain `active_entities`. No preload from `technician_documents`. |
| `PinnedDocumentsController` | `create` / `destroy`; binds pins to the signed-in user’s web session (`identifier` = `user.id`, `channel: "web"`). |
| `HomeController#pinned_uris_for_current_session` | `Set` of `SessionContextBuilder.entity_s3_uris(session)` for row UI (`data-selected`, checkbox). |
| `rag_chat_controller.js` | Optimistic toggle + `fetch` to `/pinned_documents` with CSRF JSON headers. |
| `RagQueryConcern#execute_rag_query` | Pinned URIs only for the metadata filter; `force_entity_filter` defaults to **true** when any pin exists. `KbDocumentResolver` still contributes **`## Query Resolution`** text to the prompt—it does **not** merge resolver hits into filter URIs. |
| `KbDocumentEnrichmentService` | Post-answer enrichment of **`kb_documents`** from Haiku doc refs + retrieved citations. |
| `BedrockIngestionJob#register_entity` | Auto-`pin_kb_document!` the `KbDocument` for the session that started the upload. |
| `BedrockRagService` | Web delivery favors concise field answers; forced pinned queries remain scoped to selected documents and return `DATA_NOT_AVAILABLE` instead of retrying globally. |

**Tests (non-exhaustive):** `test/models/conversation_session_test.rb` (TTL, pin/unpin), `test/controllers/pinned_documents_controller_test.rb`, `test/services/kb_document_enrichment_service_test.rb`, `test/services/session_context_builder_test.rb`, ingestion/RAG tests updated for auto-pin and `force_entity_filter`.
