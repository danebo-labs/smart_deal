# Operational Scripts

Entry points, not logic. Anything worth reusing lives in `app/services` where it
is unit-tested; a script here only reads env vars, calls the service and prints.
If you are about to write more than ~40 lines of logic in this directory, put it
in a service and leave a wrapper here.

## Running against production

The deployed image does **not** contain `script/`, so `bin/rails runner
script/…` fails with *file could not be found*. Pass the script on **stdin**
instead — no redeploy needed:

```bash
CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker ps --filter label=service=smart-deal --filter label=role=web \
   --filter status=running --format '{{.Names}}' | head -1")
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker exec -i -e BULK_UPLOAD_ID=7 $CID bin/rails runner -" \
  < script/bulk_upload_status.rb
```

**A script passed on stdin still runs inside the deployed image**, so it can only
call classes that image contains. `bulk_upload_status.rb` and
`bulk_upload_recover_failed.rb` need `BulkUploadStatusReport` /
`BulkUploadAssetRecovery` deployed; `bulk_upload_cost_audit.rb` works against any
version because it is self-contained. When a service is not deployed yet and a
ZIP is in flight, do **not** deploy to get it — inline what you need for that one
run instead. A deploy restarts the worker, and `PollClaudeBatchJob` has a 24h
`HARD_TIMEOUT` from its first attempt: coming back late marks the upload `failed`
over results already paid for.

Two rules that have already caused incidents:

- **Pin the role.** `kamal app exec` runs on *every* role, so a `create!` runs
  twice and the second collides with the unique index on `bulk_uploads.sha256`.
  Use `--roles=web`, or `docker exec` on the web container as above.
- **Wrap polling reads in `ActiveRecord::Base.uncached`.** `bin/rails runner`
  leaves the query cache on for the whole process, so a loop re-reads its first
  answer forever and reports a frozen state. `BulkUploadStatusReport` already
  does this.

## Bulk ingestion toolkit

| Script | Effects | What it is for |
|---|---|---|
| `bulk_upload_status.rb` | read-only | Asset states, the error behind each failure, and the field_records the parser discarded. `FOLLOW=true` polls until `complete`/`failed`. |
| `bulk_upload_cost_audit.rb` | read-only | All-in cost of one run from `bedrock_queries`: batch **plus** the `page_filter` and `bulk_retry` direct routes, which add 9-15%. Includes cache tokens, which `bulk_upload_assets` counters cannot price. |
| `bulk_upload_recover_failed.rb` | **writes** | Recovers assets that failed *after* their results arrived, without paying again: back to `in_batch`, then `IngestBatchResultsJob`. Anthropic keeps results ~29 days and re-reading is not billed. |
| `pdf_split_peak_audit.rb` | read-only | Disk a ZIP will write while splitting pages, against the host's free space. **Run this before uploading any ZIP**, and re-run rather than reusing a figure recorded before 2026-08-22 — see below. |
| `split_oversized_pdfs.rb` | writes locally | Cuts PDFs over `ZipExtractionService::MAX_FILE_BYTES` into page-range parts and builds a verified ZIP. That limit **aborts the whole archive**, it does not skip the entry. |
| `gonzalo_corpus_prep.rb` | writes locally | Inventory, budget and ZIP bins for a manual corpus, validated with the real `ZipExtractionService`. Bins by **source bytes**, which does not bound disk — see below. |
| `../bin/worker_watch` | read-only | Samples worker memory against its cgroup limit and alerts when the container stops. The worker dies by cgroup OOM during submission and SolidQueue cannot rescue a SIGKILL, so nothing else reports it. |

Cost figures are authoritative from the audit script, not from
`bulk_upload_assets.claude_*_tokens`: those sum cache tokens into the input
count, which cannot then be priced.

### Disk is a first-class budget, and source bytes do not measure it

`BulkCostV2RequestBuilder#collect_pages` materialises **every page of a document
as its own PDF** before filtering, so the peak is `pages × per-page size` and a
ZIP's own size does not bound it. That is what killed `04_ingesta` at page 383
with `No space left on device`.

> ⚠️ **Corrected 2026-08-22.** This section used to say per-page extraction
> "copies the document's shared resource tree into each page", and quoted 10.4 MB
> per page / 5.61 GB / ~350x as properties of the PDF. The mechanism was wrong and
> the numbers measured a **defect**: a page's `/B` entry (article-thread beads)
> chains to every other page on the thread, so importing one page dragged 435
> orphan pages and their images along. Pruned via
> `PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS`, that manual goes from
> 12.296 MiB to 0.097 MiB per page and from 6.18 GiB to **17.9 MiB** for all 515
> pages — 355x — with identical extracted text and a byte-identical 150 dpi
> raster. **Every peak figure recorded before that date is stale by up to 355x.
> Re-measure; never reuse a stored budget.**

Consequences to respect:

- **Budget by `pages × per-page size`, never by ZIP size.** Source bytes are
  still not a predictor. Run `pdf_split_peak_audit.rb` before every upload; it
  fails with exit 1 over budget. It shares the splitter's prune, so it reports
  what the splitter actually writes today, not the historical figure.
- **Measure exactly, do not sample, to clear a tight budget.** `SAMPLE_PAGES`
  exists to triage a large corpus, not to authorise a ZIP: per-page size is not
  uniform, so a sample can miss the pages that matter.
- **One heavy manual per ZIP** remains the cheap default, but it is no longer
  forced by disk for a threaded scan. Splitting costs nothing in API terms — the
  same pages are billed either way.
- A disk failure during splitting happens **before** the page filter is called,
  so it costs nothing. A failure after it does: `04_ingesta` burned US$1.44 of
  filtering for zero batches. Never re-run a failed ZIP unchanged.
- `bin/worker_watch` prints `disk_libre` and raises `DISK_ALERT` under
  `DISK_MIN_GB` (default 3). Watch it during any run with a heavy manual.

### Memory is a budget too, and the ceiling is not the fix

The worker runs under a **2 GiB cgroup** (`config/deploy.yml`, gitignored — never
regenerate it from git) with 4 GB of host swap; the web container gets 1.5 GiB on
a `t3.medium` (3,831 MB). A cgroup limit is a **cap, not a reservation**: AWS does
not bill it, so raising it saves nothing and lowering it buys nothing. At rest the
worker sits around 570-700 MiB.

`IngestBatchResultsJob(8)` still took a SIGKILL at that 2 GiB ceiling, because
`BatchPageRetryService` extracted **all** 515 pages to retry a handful. The fix
was to bound the work (`each_page(only:)`) and the per-page cost (the `/B` prune),
not to raise the ceiling. Reach for a bigger `memory:` only after the peak itself
is bounded and measured — and never with a ZIP in flight, since a deploy restarts
the worker and `PollClaudeBatchJob` has a 24h `HARD_TIMEOUT`.

## Conventions

- Read-only by default. A script with effects states it in its header comment.
- Scripts with effects must be **idempotent** and must **guard**: refuse when
  assets are in flight, when a named file does not exist, when the upload has no
  batch ids to re-read. A silent no-op is worse than a refusal.
- Never bump `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION` to work around a
  parse defect: it invalidates the `(account, SHA-256, contract)` dedupe and
  forces a re-billed re-parse of everything ingested so far.
- Dated filenames (`*_2026-07-29.rb`) are finished one-offs kept for the record.
  Do not extend them; they assume state that no longer exists.
