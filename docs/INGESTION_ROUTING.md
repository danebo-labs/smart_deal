# Ingestion routing — file type, page filter, LLM selection

How the app decides **what to parse**, **which pages to keep**, and **which Claude model** to use when a technician uploads a file from **chat** or **bulk ZIP**.

**Related:** [Web custom chunking](WEB_CUSTOM_CHUNKING.md) · [Bulk ZIP](BULK_INGESTION.md) · [Cost v2 ADR](INGESTION_COST_V2.md) · [Metrics channels](METRICS.md)

---

## Entry points

| Entry | Route | Job queue | Parse API |
|-------|-------|-----------|-----------|
| **Chat attachment** | Home RAG → `UploadAndSyncAttachmentsJob` → `QueryOrchestratorService#upload_and_sync_attachments` | `default` | Sync Messages (default) or Anthropic Batch (cost v2 manuals) |
| **Bulk ZIP** | `/bulk_uploads` → `ProcessBulkUploadJob` → … → `SubmitClaudeBatchJob` | `bulk_ingestion` | Anthropic Message Batches (always async) |

Both paths share the same **classification**, **page filter**, and **model routing** services when custom chunking / cost v2 flags are on. Without flags, chat uploads use legacy Bedrock FM parse (`BEDROCK_DATA_SOURCE_ID` / `OWRPGSX6XK`); bulk ZIP uses whole-file Opus batch requests.

---

## Feature flags (summary)

| Flag | Default | Effect |
|------|---------|--------|
| `CUSTOM_CHUNKING_WEB_ENABLED` | off | Chat uploads → direct Claude parse + `BEDROCK_BULK_DATA_SOURCE_ID` (chunking NONE) |
| `CUSTOM_CHUNKING_COST_V2_ENABLED` | off | Sonnet default for photos; manuals → per-page Batch; unified `PageRelevanceFilter.filter_pages`; SHA dedup |
| `MANUAL_FORCE_SYNC` | off | Force sync parse for all manual PDFs/Office (ops override) |
| `FIELD_PHOTO_HAIKU_GATE_ENABLED` | off | Optional Haiku pre-gate on borderline field photos |
| `CUSTOM_CHUNKING_NO_FALLBACK` | off | Dev only — no legacy OWRPGSX6XK fallback on chat errors |

Bulk ZIP does **not** require `CUSTOM_CHUNKING_WEB_ENABLED`. `CUSTOM_CHUNKING_COST_V2_ENABLED` applies to **both** chat and bulk when set.

Full rollout: [INGESTION_COST_V2.md §6](INGESTION_COST_V2.md#6-flags-y-rollout).

---

## End-to-end flow

```mermaid
flowchart TB
  subgraph entry [Upload]
    Chat[Chat attachment]
    Bulk[Bulk ZIP asset]
  end

  subgraph classify [Zero-LLM classification]
    Router[FileMultimodalRouter]
  end

  subgraph dedup [Optional dedup]
    Sha{ContentDedupService<br/>sha256 complete?}
  end

  subgraph office [Office path]
    Libre[OfficeToPdfConverter]
  end

  subgraph filter [Page filter — PDF multipage only]
    FP[PageRelevanceFilter.filter_pages]
    BatchH[Haiku call_batch ≥2 pages]
    SingleH[Haiku per-page gate = 1 page]
    Heur[Heuristic rules — zero LLM]
  end

  subgraph parse [Parse]
    Sonnet[Sonnet 4.6]
    Opus[Opus 4.7]
    HaikuRAG[Haiku 4.5 — RAG queries only]
  end

  Chat --> Sha
  Bulk --> Sha
  Sha -->|hit| Skip[Skip parse — reuse KB identity]
  Sha -->|miss| Router
  Router -->|Office| Libre --> Router
  Router -->|image / text / pdf| FP
  FP --> BatchH
  FP --> SingleH
  BatchH --> Heur
  SingleH --> Heur
  Heur -->|keep| Sonnet
  Heur -->|keep + force_opus| Opus
  Heur -->|drop| Drop[Page skipped — no parse cost]

  Chat -.->|RAG question| HaikuRAG
```

---

## Step 1 — File type classification

`FileMultimodalRouter` (`app/services/file_multimodal_router.rb`) inspects MIME type and extension. **No LLM calls.**

| Input | `mode` | Initial model hint | Next step |
|-------|--------|-------------------|-----------|
| Plain text (.txt, .md, .csv, .html, …) | `:text` | Sonnet | Single Claude call |
| Image (JPEG/PNG/GIF/WebP) | `:image` | Sonnet (cost v2) / router default | `FieldPhotoDensityGate` → Sonnet or Opus |
| PDF, 1 page | `:pdf_text_only` | Sonnet | Single call on whole PDF |
| PDF, ≥2 pages | `:pdf_mixed` | Per-page (see below) | Split → `PageRelevanceFilter` → N calls on kept pages |
| Office (.docx, .xlsx, .pptx, …) | `:office` | — | `OfficeToPdfConverter` → re-classify as PDF |

**Per-page model downgrade** (inside `:pdf_mixed`, before relevance filter):

- Text-only page → Sonnet
- Page with images but `text_chars > 500` and `image_area_ratio < 0.20` → **downgrade to Sonnet** (conservative)
- Scanned / rasterized page (`text_layer < 100`, `image_ratio > 0.7`, or high pixel density without XObjects) → **Opus** (`force_opus` from filter)

Parallelism: up to **`MAX_PARALLEL_PAGES=8`** concurrent page requests on the sync path.

---

## Step 2 — Page relevance filter

`PageRelevanceFilter` (`app/services/page_relevance_filter.rb`) drops **boilerplate pages** before expensive Sonnet/Opus parse calls. Applied to **multi-page PDFs** (native or converted from Office).

### Routing mode

| Pages in document | Filter mode | LLM cost |
|-------------------|-------------|----------|
| **1** | Per-page cascade: heuristics → optional Haiku gate | 0–1 Haiku calls |
| **≥2** | **`filter_pages` → `call_batch`**: one Haiku call classifies **all** pages | 1 Haiku call |

Unified routing (2026-05-22): native PDFs and Office/PPT decks use the same `filter_pages` entry point. The old `office_origin && pages.size > 1` branch is removed.

### Heuristic drops (zero LLM)

Applied first on single-page path; batch mode delegates classification to Haiku for multi-page docs.

| Reason | Rule |
|--------|------|
| `cover_slide` | Page 1, text layer `< 10` chars, image ratio `> 0.7`, visible text `< 50` chars |
| `title_page` | Page 1, text `< 400` chars, matches title pattern (`manual`, `guide`, `guía`, …) |
| `boilerplate` | Text `< 600` chars, matches copyright / preface / index / `índice` / `table of contents` / … |
| `repeated_artifact` | Same text on ≥3 pages (running header/footer) |
| `blank` | Text `< 50` chars, no images |
| `table_of_contents` | ≥10 lines and ≥30% of lines end with a page number |

### Heuristic keeps

| Reason | Rule |
|--------|------|
| `scanned_image` | `text_layer < 100` and `image_ratio > 0.7` → **keep** + **`force_opus: true`** |
| `high_confidence_content` | Text `> 800` chars, or images with ratio `≥ 0.25` |

### Ambiguous pages (single-page path only)

Text 50–800 chars, no clear signal → **Haiku 4.5 gate** (one page PDF in the message). Returns `{keep, reason}`. On error → **keep** (safe default).

### Batch classifier (`call_batch`)

One Haiku message with **all N single-page PDF blobs**. Prompt instructs aggressive drops:

- **Drop:** cover, title, agenda, index, table of contents, section divider, blank, preface, copyright
- **Keep:** wiring diagrams, procedures, specs, data tables, component photos

Tracking: `page_filter_batch: <filename> 1..N/N` in `bedrock_queries`.

Typical yield: ~**75%** of pages kept on 10-page manuals (see [INGESTION_COST_V2.md](INGESTION_COST_V2.md) cost projection).

---

## Step 3 — LLM and prompt matrix

Models (`BatchChunkingPrompt`):

- **Sonnet 4.6** — `MODEL_TEXT` — default parse
- **Opus 4.7** — `MODEL_MULTIMODAL` — dense scans, large field photos
- **Haiku 4.5** — page filter + optional photo gate only (not chunk generation)

| File type | Filter | Parse model | Prompt | API mode (chat) | API mode (bulk) |
|-----------|--------|-------------|--------|-----------------|-----------------|
| **Field photo** | `FieldPhotoDensityGate` (size ≥1.5 MB → Opus; optional Haiku gate) | Sonnet (default) or Opus | `FieldPhotoPrompt` (Sonnet) / `BatchChunkingPrompt` (Opus) | Sync | Batch |
| **Text file** | — | Sonnet | `BatchChunkingPrompt` | Sync | Batch (legacy whole-file) |
| **PDF 1 page** | Per-page filter if routed through mixed path; else whole doc | Sonnet | `BatchChunkingPrompt` | Sync | Batch per kept page (v2) |
| **PDF ≥2 pages** | `filter_pages` → Haiku batch | Sonnet per kept page; Opus if `force_opus` | `BatchChunkingPrompt` | Sync (v1) or Batch async (v2 default) | Batch per kept page (v2) |
| **Office** | Convert → same as PDF | Same as PDF | Same | Sync or Batch | Batch (after convert in ZIP extract) |
| **Legacy (flags off)** | None | Opus whole file | `BatchChunkingPrompt` | Bedrock FM | Batch whole file |

**Ingestion path metadata** (sidecar / metrics):

| Path | `ingestion_path` |
|------|------------------|
| Sync web parse | `web_v1` |
| Field photo Sonnet | `field_photo_v1` |
| Manual batch async | `manual_batch_v1` |
| Bulk ZIP legacy | `batch_v1` |
| SHA dedup hit | `content_dedup` |

---

## Chat upload — path selection

Requires `CUSTOM_CHUNKING_WEB_ENABLED=true`.

```
UploadAndSyncAttachmentsJob
  → CustomChunkingPipeline (per file)
      → ContentDedupService (skip parse on hit)
      → if cost_v2 && PDF/Office && !force_sync:
            SubmitManualBatchJob → ManualBatchIngestionService (async Batch)
         else:
            SingleFileChunkingService (sync Messages API)
  → BulkKbSyncService → BedrockIngestionJob
```

**Sync fallback triggers** (manual PDF/Office uses sync even with cost v2):

1. Technician attaches file **and** sends a query in the same turn (`force_sync: true`)
2. `MANUAL_FORCE_SYNC=true`

**Office failure:** no silent fallback to legacy OWRPGSX6XK — user sees `rag.office_parse_failed`. PDF/image/text errors still fall back unless `CUSTOM_CHUNKING_NO_FALLBACK`.

Detail: [WEB_CUSTOM_CHUNKING.md](WEB_CUSTOM_CHUNKING.md).

---

## Bulk ZIP — path selection

Does not use `CUSTOM_CHUNKING_WEB_ENABLED`.

```
ProcessBulkUploadJob → BatchIngestionService#process! (extract, S3, dedup)
  → SubmitClaudeBatchJob → BatchIngestionService#submit!
      → if CUSTOM_CHUNKING_COST_V2_ENABLED:
            BulkCostV2RequestBuilder (photos + per-page PDF)
         else:
            whole-file Opus requests (legacy)
  → PollClaudeBatchJob → IngestBatchResultsJob → BulkKbSyncService
```

Office files in ZIP: `ZipExtractionService` sets `office_origin`; `BatchIngestionService` may convert via LibreOffice before batch build. Page filter uses the same `filter_pages` as chat (no separate Office branch).

Detail: [BULK_INGESTION.md](BULK_INGESTION.md).

---

## SHA dedup

`ContentDedupService.find_completed(sha256:)` checks `BulkUploadAsset` rows with status `complete`. On hit:

- Skip all Claude parse calls
- Reuse `canonical_name` and `aliases`
- Chat: populate `web_v1_metadata` from dedup record
- Bulk: mark asset `complete` immediately

---

## Cost telemetry

Parse rows land in `bedrock_queries` with `source: ingestion_parse`. Classified by `LlmUsageChannel` into dashboard footer channels (Haiku direct, Sonnet/Ops direct vs batch). See [METRICS.md](METRICS.md).

Example `user_query` labels:

| Label | Meaning |
|-------|---------|
| `web_parse: manual.pdf p3/12` | Sync page parse |
| `web_batch: manual.pdf p3/12` | Async batch page parse |
| `page_filter: manual.pdf p2/12` | Single-page Haiku gate |
| `page_filter_batch: deck.pdf 1..30/30` | Multi-page Haiku batch classify |
| `bulk_batch: …` / `bulk_parse: …` | Bulk ZIP paths |

---

## Source files (implementation map)

| Concern | Service / job |
|---------|---------------|
| Chat orchestration | `CustomChunkingPipeline`, `QueryOrchestratorService` |
| Single-file sync parse | `SingleFileChunkingService`, `ClaudeChunkingClient` |
| Manual async batch (chat) | `SubmitManualBatchJob`, `ManualBatchIngestionService`, `IngestManualBatchResultsJob` |
| Bulk batch | `BatchIngestionService`, `BulkCostV2RequestBuilder`, `ClaudeBatchClient` |
| Classification | `FileMultimodalRouter` |
| Page filter | `PageRelevanceFilter` |
| Photo routing | `FieldPhotoDensityGate`, `FieldPhotoPrompt`, `FieldPhotoResultsParser` |
| Office convert | `OfficeToPdfConverter` |
| Merge multi-page | `ChunkMergerService`, `BatchResultsParserService` |
| KB sync | `BulkKbSyncService`, `BedrockIngestionJob` |
| Dedup | `ContentDedupService` |
