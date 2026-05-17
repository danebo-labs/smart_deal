# WhatsApp / Twilio (dormant)

> **Current build:** inbound webhook **not mounted** (`config/routes.rb`). WA jobs exist in code but are **not enqueued**. Tests skip `Whatsapp`/`Twilio` classes unless `WHATSAPP_CHANNEL_DISABLED=false`.

**Product scope:** [README](../README.md#product-scope-current-build)

---

### WhatsApp (Twilio + Ngrok) — dormant / reactivation

> **Current build:** inbound WhatsApp is **not** wired (`post '/twilio/webhook'` commented in `config/routes.rb`). The steps below are the **historical** procedure to turn the channel back on after restoring the route, queue workers, and collapsed code branches.

This section describes how **Twilio WhatsApp Sandbox + Ngrok** were used to exercise the app before the WA decouple.

#### Overview

When enabled, the app received WhatsApp messages via Twilio; the webhook triggered the RAG flow so technicians could query the knowledge base from their phones.

#### Prerequisites

- Ruby on Rails application running locally
- Twilio account with access to the WhatsApp Sandbox
- Ngrok installed
- Rails server listening on port 3000

#### Steps to enable the integration locally (after re-mounting the webhook)

1. **Start the Rails application**

   Start the Rails server so it listens on `http://localhost:3000`:

   ```bash
   bin/dev
   ```

   Ensure the app is reachable at `http://localhost:3000` before continuing.

2. **Expose the application with Ngrok**

   In a new terminal tab, run Ngrok to expose your local server:

   ```bash
   ngrok http 3000
   ```

   Ngrok will display a public URL (e.g. `https://xxxxx.ngrok-free.dev`). This URL may change each time you start Ngrok.

3. **Configure the WhatsApp webhook in Twilio**

   - Open the Twilio Console: [https://console.twilio.com/us1/develop/sms/try-it-out/whatsapp-learn](https://console.twilio.com/us1/develop/sms/try-it-out/whatsapp-learn)
   - Go to **Develop → Messaging → Send a WhatsApp message**
   - In the **"When a message comes in"** section:
     - Paste your Ngrok public URL
     - Set the HTTP method to **POST**
     - Append the Rails webhook path so the full URL points to your app (e.g. `https://xxxxx.ngrok-free.dev/twilio/webhook`)

   Example of a complete webhook URL:

   ```
   https://xxxxx.ngrok-free.dev/twilio/webhook
   ```

   Replace `xxxxx` with your actual Ngrok subdomain.

4. **Add participants to the WhatsApp Sandbox**

   To allow users to interact with the app via WhatsApp:

   - Send a WhatsApp message to **+1 415 523 8886**
   - Send the exact text: `join having-week`

   After that, those users can send messages to the sandbox number and receive RAG responses from the application.

#### Important notes

- **Webhook URL updates:** Every time you restart Ngrok, the public URL changes. You must update the "When a message comes in" URL in the Twilio Console with the new Ngrok URL.
- **Development use:** This setup is intended for local development and testing. For production, use a stable public URL and follow Twilio's production WhatsApp requirements.
- **RAG flow (when enabled):** Incoming WhatsApp messages hit the `/twilio/webhook` endpoint and trigger the application's RAG flow, which queries the knowledge base and replies via WhatsApp.

---

## Answer cache & follow-up classifier (R3)

### WhatsApp Answer Cache & Follow-up Classifier (R3)

> **Status (dormant):** the **R3** stack below (`Rag::WhatsappAnswerCache`, `SendWhatsappReplyJob`, classifier, faceted renderers) remains **in the codebase** but is **not exercised** while Twilio is decoupled. Read this section when **re-enabling WhatsApp**.

A short-lived **conversational UI cache** was designed to make WhatsApp **navigation** feel lightweight: the first message shows `[RESUMEN]` plus a **numbered menu** (pinned **1 = risks**; `2`..`N-1` = model-chosen section labels such as considerations / components / step-by-step for an installation; **last slot = new query**). Tapping a number or an allowlisted command **expands from the cached full text without re-invoking Bedrock** — the full structured answer (including all section bodies) was already produced in one RAG call and is stored in cache. It **does not replace** `ConversationSession`; both coexist. Multi-document questions are first-class: `[DOCS]` + per-section `## <label> | <sources>` keep attribution correct.

> **Safety policy — closed allowlist.** The cache only serves messages that match an explicit set of **navigation tokens** (digits that appear in the cached `menu` row for this answer, or fixed words for redraw/reset; **not** open-ended “facet keywords”). **Free-text questions are never served from cache** — e.g. `voltaje`, `torque tornillo m8` always run a fresh RAG. Trade-off: lower cache hit rate on free text, higher Bedrock cost. **Safety > token spend**. See `Rag::WhatsappFollowupClassifier` docstring.

```
ConversationSession  →  pins + conversation_history for prompts; sliding row TTL (EXPIRY_DURATION)
Rag::WhatsappAnswerCache  →  last RAG “card” (structured sections + menu) for menu UX, per recipient
```

| Layer | Time horizon | Scope | Backing store |
|---|---|---|---|
| `conversation_sessions` | Row TTL **30 days** sliding by default (`EXPIRY_DURATION`; refreshed on pin flows) | `identifier` + `channel` (one shared row in MVP pilot when enabled) | PostgreSQL `conversation_sessions` |
| `Rag::WhatsappAnswerCache` | Turn-set | **Per WhatsApp `to` number** (not shared across technicians) | `Rails.cache` (Solid Cache) key `rag_wa_faceted/v4/<whatsapp_to>` — TTL **1800s** (30 min). Bumped v3 → v4 when the payload switched from `faceted`+`document_label` to `structured` (no session-derived document label; avoids stale source-label mix); stale v3 payloads are invalidated as `op=corrupt`. |
| Sticky thread locale | Longer follow-up | Same `to` | `rag_whatsapp_conv/v1/<whatsapp_to>` (written by `RagQueryConcern`; TTL **7 days**) so very short follow-ups can inherit language after the 30 min faceted TTL expires. |

**Why per-number cache even in shared-session MVP?** The pilot may use one `ConversationSession` row for everyone, but two technicians on different phones must not share the same in-progress menu/answer: collision would mix topics and is unsafe. Isolation is by `whatsapp:+…` (cache key), not by shared session.

#### Cache value schema (`Rag::WhatsappAnswerCache`)

`WhatsappAnswerCache` validates a fixed set of keys (`SCHEMA_KEYS` in `app/services/rag/whatsapp_answer_cache.rb`). A typical payload:

```ruby
{
  question:         String,   # last user question that produced this card
  question_hash:    String,   # SHA1 prefix (debug)
  structured: {              # from Rag::FacetedAnswer#to_cache_hash
    intent:   Symbol,        # e.g. :identification, :installation, :emergency
    docs:     [String, ...], # from [DOCS] JSON in the model output
    resumen:  String,        # summary block
    riesgos:  String,        # risks block; always slot 1 in [MENU] as __riesgos__
    sections: [ { n:, key: :sec_1, label:, sources: [String, ...], body: String }, ... ],
    menu:     [ { n:, label:, kind: :riesgos | :section | :new_query, section_key: ... }, ... ],
    raw:      String
  },
  citations:         Array,
  doc_refs:          Array,
  locale:            Symbol,  # :es | :en
  entity_signature:  String,  # 12 hex chars: SHA1 of sorted active_entities keys; drift can invalidate
  generated_at:      Integer
}
```

- **EMERGENCY** intent is **never written** to cache (`[WA_CACHE] op=skip_write reason=emergency`); safety answers are always full RAG.
- **Corrupt / schema drift (missing keys)** on read: entry deleted, `nil` returned, log line `[WA_CACHE] op=corrupt …`.
- **Entity drift** (cached signature ≠ live `active_entities`): `invalidate` + miss — **skipped** when `SharedSession::ENABLED` (see `SharedSession` in code), because shared pilots mutate the same entity set for unrelated reasons.

#### Components

| Component | File | Role |
|---|---|---|
| `Rag::FacetedAnswer` | `app/services/rag/faceted_answer.rb` | Parses Bedrock’s structured blocks (`[INTENT]`, `[DOCS]`, `[RESUMEN]`, `[RIESGOS]` pinned, `[SECCIONES]`, `[MENU]`) and renders the first message + per-section detail from cache. `legacy?` = model emitted no structure → plain `format_rag_response_for_whatsapp` + no cache write. Block names are Spanish protocol literals from the prompt contract. |
| `Rag::WhatsappAnswerCache` | `app/services/rag/whatsapp_answer_cache.rb` | Read/write/invalidation + logs: `op=read|write|corrupt|skip_write` and `op=invalidate` when **entity_drift** is detected (non–shared mode). |
| `Rag::WhatsappFollowupClassifier` | `app/services/rag/whatsapp_followup_classifier.rb` | **Strict** closed-allowlist: `inicio`/`start`/`home` → `reset_ack_with_picker` · `nuevo`/`nueva`/`new`/`reset` → `user_reset` (cache only) · digits `1`..`N` resolved against the **cached** `menu` (slots include `__list_recent__` → `:show_doc_list :recent`, `__list_all__` → `:show_doc_list :all`, legacy `__new_query__` → reset) · everything else (including former redraw words like `menu`/`volver`/`mas`) is **`:new_query`** — the menu is rendered as a footer on every message so a redraw shortcut is unnecessary. Spanish tokens are accepted user commands. Emits `[WA_CLASSIFIER] route=… reason=…`. |
| `Rag::WhatsappPostResetState` | `app/services/rag/whatsapp_post_reset_state.rb` | Short-lived (5 min) Rails.cache state after **picker reset** (`:reset_ack_with_picker`): `picking_source` → `picking_from_list` until the user picks a doc or abandons. |
| `Rag::WhatsappDocumentPicker` | `app/services/rag/whatsapp_document_picker.rb` | Builds numbered lists for **recent** vs **all** and seeds `Describe <name>` into the normal `:new_query` RAG path. |
| `SendWhatsappReplyJob` | `app/jobs/send_whatsapp_reply_job.rb` | `perform_faceted` / `perform_legacy`; post-reset picker short-circuits before the classifier when `WhatsappPostResetState` is present. Orchestrates cache, classifier, RAG, `infer_locale` (cache → sticky conv key → history heuristic → body → `I18n.default_locale`). **Does not** prepend a separate “consulted documents” header to structured first messages — sources come from `[DOCS]` and section headers. |
| `ProcessWhatsappMediaJob` | `app/jobs/process_whatsapp_media_job.rb` | After a successful `KbSyncService` upload: `invalidate(whatsapp_to)` and `[WA_CACHE] op=invalidate reason=media_upload` so the next user question runs RAG over the updated KB. |

#### Classifier cascade (order in code; first match wins)

The classifier is a **strict closed allowlist** of navigation inputs: a digit that resolves against the cached menu, or one of the explicit reset tokens. Anything else — including former soft-nav words like `menu`, `volver`, `regresar`, or `mas` — is treated as a content question, the cache is invalidated, and a fresh RAG call runs. There is **no** synonym map, no length heuristic, no LLM-based "intent guessing", and no menu-redraw shortcut (the menu is already rendered as a footer on every message).

1. **`:reset_ack_with_picker`** — `inicio`, `start`, `home` → invalidate cache, static ack with **1=recent / 2=all**, arm `WhatsappPostResetState` (**no** RAG on this turn for the RAG part).
2. **`:user_reset`** — `nuevo`, `nueva`, `new`, `reset` **or** the menu digit whose `kind` is `:new_query` (legacy cache compat) → invalidate cache, short ack (no file-picker); **no** RAG.
3. **Empty cache + only digits** that look like a menu pick → `:no_context_help` (`:menu_without_cache` or `:digit_out_of_range`).
4. **Empty cache + free text** — `:new_query` (`:no_cache`).
5. **Digit** — resolve against the **cached** `menu` for this answer:
   - `kind: :riesgos` / `:section` → `:section_hit` if the body is non-empty; empty → `:new_query` (`:empty_section_reconsult`).
   - `kind: :list_recent` / `:list_all` → `:show_doc_list` (renders TechnicianDocument or KbDocument list, arms `WhatsappPostResetState` `PHASE_PICKING_FROM_LIST`; the next digit picks a doc → seeded `:new_query` → cached).
   - `kind: :new_query` (legacy) → same as **`:user_reset`**.
   - Unknown digit → `:no_context_help` (`:digit_out_of_range`).
6. **Default** — `:new_query` (`:content_query`).

Matching is on the **fully normalized token** (NFD → strip accents → lowercase → strip → collapse spaces), not substring presence. Literal words like `riesgos`, `menu`, or `mas` in free text are **not** shortcuts — only the menu digit (or one of the four reset tokens) is recognised as navigation.

If the model omits structured labels (`FacetedAnswer#legacy?`), the job does not populate the WhatsApp answer cache; behavior matches the legacy `perform_legacy` single-message path (citations header/footer as before when applicable).

#### Observability & scripts (WhatsApp path — re-mount webhook to use)

- **`bin/wa_dev_sim "<message>"`** — one-off POST to `/twilio/webhook` (requires route + workers restored); logs a marker in `development.log`.
- **`bin/wa_e2e_monitor`** — highlights `[WA_CLASSIFIER]`, `[WA_CACHE]`, `[WA_FACET_DELIVERY]`, and Bedrock lines in `log/development.log`.
- **`bin/wa_e2e_run`** — E2E markers per case (`E2E_CASE_12`, …) for grepping a single run.
- **`bin/wa_metrics_daily`** — rollups of cache ops and classifiers (see script).
- **`bin/wa_dev_clear <whatsapp:+…>`** — deletes `rag_wa_faceted/v4/...` (or whatever current `WhatsappAnswerCache::VERSION` is), `rag_wa_post_reset/v1/...`, and `rag_whatsapp_conv/v1/...` for a number. When shared session is on, it does **not** destroy the `mvp-shared` row (prints a one-liner to do that manually if needed).

#### R3 WhatsApp flags (detail)

The WhatsApp structured-cache flags appear in the [MVO pilot flags](../README.md#configuration-flags) table above. Summary:

| Variable | Default | Effect |
|---|---|---|
| `WA_FACETED_OUTPUT_ENABLED` | `true` | `false` → `SendWhatsappReplyJob` uses `perform_legacy` (single message, no read-through cache). |
| `WA_PROCESSING_ACK_ENABLED` | `true` | `false` → suppresses the processing bubble before full RAG calls. Ack is sent before **every** full RAG call: `:new_query` **and** `perform_legacy`. Cache hits, doc-list slots (6/7), and section follow-ups stay silent. Log line: `[WA_ACK] to=<to> reason=new_query_before_rag`. |

> **Removed flag (`WA_NANO_CLASSIFIER_ENABLED`).** The Haiku-nano sub-classifier and the synonym map were removed as part of the safety-policy refactor. Remove it from your `.env` if present.

Typical interaction **when Twilio is active:** **0** Bedrock calls when the technician taps a menu number / allowlisted command; **1** full RAG when they type free text. The full RAG path is optionally preceded by the processing-ack bubble when the flag is on.

#### Section rendering (R3 UX)

- **Vertical text-only menu** — first message lists `N - <label>` for each `[MENU]` row. Emojis from the model are stripped in render. The application appends two file-listing slots after Haiku's dynamic sections: **recent consulted files** (`__list_recent__`) and **all files** (`__list_all__`); the legacy "new query" slot was removed (any free-text reply is a new query).
- **Multi-doc banner** — if `[DOCS]` has **≥2** entries, a `rag.wa_docs_banner` line appears *above* `[RESUMEN]`; single-doc answers skip the banner. Section follow-ups use `*<Section> · <sources>*` (or a two-line fallback for very long source lists) — sources come from each `##` header, not from `active_entities` (fixes the old stale-label bug).
- **Pinned risks** — always menu slot 1; body comes from the `[RIESGOS]` block (safety).
- **Reset + file picker** — **`inicio` / `start` / `home`** (not the last new-query digit) show the **1 — recent / 2 — all** prompt and arm `WhatsappPostResetState`. Picking a doc seeds `Describe <name>`. **`nuevo` / `nueva` / `new` / `reset`**, or the new-query menu number, only invalidate the faceted cache and show a short ack (no file list).
- **No semantic “keyword → cached facet” routing** — `voltaje`, `riesgos` as free text, etc. are always full RAG (`:content_query`).

For multi-tenant work later, keep treating **session row** and **per-number faceted cache** as separate concerns: a future `account_id` / `project_id` can scope the session and KB, while the WhatsApp cache key should remain tied to the **recipient address** to avoid cross-user menu bleed.
