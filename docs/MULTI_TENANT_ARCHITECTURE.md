# Multi-Tenant Architecture

## Status

Danebo is currently a single-tenant MVP. Before onboarding multiple customer
accounts, tenant isolation must be implemented across Rails, S3, Bedrock
metadata, retrieval filters, jobs, caches, broadcasts, and metrics.

This document records the target architecture. It intentionally assumes that
existing MVP data can be replaced rather than migrated.

### Delivered (Stage 1 — partial)

| Area | Status | Doc |
|------|--------|-----|
| Host → `Account.slug` map (`AccountHosts`, `AccountHostResolver`) | Live | [PRODUCTION.md](PRODUCTION.md#tenant-hosts-host--account) |
| Login / session scoped to host account (`user.account_id` must match) | Live | `Users::SessionsController`, `ApplicationController#ensure_user_belongs_to_host_account!` |
| KB list and ingestion scoped by `account_id` | Live | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) |
| **Visual branding** (`display_name`, `branded`, static logo/favicon per slug) | Live for `elevadores-climb` | [ACCOUNT_BRANDING.md](ACCOUNT_BRANDING.md) |

Bedrock retrieval `account_id` metadata filter, S3 key prefixes, and full rollout
gate below remain **not** complete for a second paying customer.

## Infrastructure Decision

The default SaaS topology is shared infrastructure with logical isolation:

| Resource | Topology |
|----------|----------|
| Bedrock Knowledge Base | One shared KB |
| Bedrock S3 data source | One shared data source |
| Aurora PostgreSQL / pgvector | One shared vector store |
| S3 bucket | One shared bucket with account-scoped keys |
| Rails primary database | Shared tables with mandatory `account_id` |

A data source per tenant is not the target design. Amazon Bedrock currently
allows a maximum of five data sources per Knowledge Base, and only one ingestion
job can run concurrently per Knowledge Base. The five slots must be reserved
for genuinely different shared ingestion contracts, not customer accounts.
Tenant isolation therefore cannot depend on separate data sources.

Do not provision an Aurora vector store per tenant. The fixed database cost and
operational overhead are not commercially scalable.

| Offering | Knowledge Base | Vector store | Isolation |
|----------|----------------|--------------|-----------|
| Standard SaaS | Shared | Shared Aurora PostgreSQL / pgvector | Logical isolation through mandatory `account_id` metadata |
| Isolated customer | Dedicated | Dedicated Amazon S3 Vectors vector bucket and index | Physical vector-store isolation |

The isolated offering may also use a dedicated source bucket or AWS account
when required by contract. It must not reuse the shared Aurora vector store.
Because AWS positions S3 Vectors as cost-effective storage for infrequent-query
workloads, validate retrieval latency and expected query volume before offering
this tier. Also design its metadata contract within the S3 Vectors limits of
1 KB of custom metadata and 35 metadata keys per vector.

## Bedrock Data Source Contract

The shared S3 data source must be configured with:

```text
S3 URI:             s3://<bucket>/bulk_chunks/
Chunking strategy:  NONE
Deletion policy:    DELETE
```

Only app-generated text chunks and their sidecars belong under
`bulk_chunks/`. Original files remain outside the ingestion prefix:

```text
uploads/<account_id>/<document_id>/original.ext
bulk_uploads/<account_id>/<document_id>/original.ext
bulk_chunks/<account_id>/<document_id>/chunk_0.txt
bulk_chunks/<account_id>/<document_id>/chunk_0.txt.metadata.json
```

The inclusion prefix limits file classes, not tenants. It prevents the shared
text data source from reprocessing original images and PDFs.

See [BEDROCK_SETUP.md](../BEDROCK_SETUP.md#required-s3-data-source-configuration)
for the operator runbook.

## Isolation Invariant

Every tenant-owned resource must have an immutable account identity. A request
must never infer access from a filename, S3 URI supplied by the browser, record
ID alone, or model output.

The minimum chunk metadata contract is:

```json
{
  "metadataAttributes": {
    "account_id": "acct_123",
    "document_id": "doc_456",
    "original_source_uri": "s3://bucket/uploads/acct_123/doc_456/original.pdf",
    "original_filename": "manual.pdf"
  }
}
```

`account_id` and `document_id` must be Rails-generated values. They must not
come from the user-controlled filename.

## Retrieval Contract

Every Bedrock `Retrieve` and `RetrieveAndGenerate` call must include the account
filter, including global-catalog searches with no pinned document:

```ruby
{
  and_all: [
    { equals: { key: "account_id", value: account.id.to_s } },
    optional_document_filter
  ].compact
}
```

Rules:

1. Missing account context raises an error before calling Bedrock.
2. The account filter is mandatory and cannot be overridden by `custom_config`.
3. A no-results retry may remove a document/pin filter, but never `account_id`.
4. Citation processing must reject results whose metadata account differs from
   the authenticated account.
5. Background jobs receive `account_id` explicitly; they do not rely on
   request-local `Current`.

Metadata filtering is the primary Bedrock isolation boundary. S3 prefixes add
defense in depth and operational clarity, but retrieval must not depend on
prefix parsing.

## Ingestion Contract

### Near-term

The current `StartIngestionJob` operation synchronizes the configured data
source. With one shared data source, a sync can scan chunks belonging to all
accounts, even when only one account uploaded a document. The account metadata
still isolates retrieval, but sync work and concurrency remain shared.

Required controls:

- write the chunk and sidecar before starting ingestion;
- include `account_id` in every sidecar;
- serialize or coalesce sync requests because Bedrock permits one concurrent
  ingestion job per Knowledge Base;
- track ingestion status using account-scoped cache keys and broadcasts;
- never report another account's filenames or job state.

### Scale path

Use `IngestKnowledgeBaseDocuments` for targeted per-document indexing when
upload volume makes full data-source sync inefficient. For an S3 data source,
the request can identify the exact S3 chunk objects to ingest.

Operational requirements:

- persist the same documents and metadata in S3;
- do not run direct ingestion concurrently with `StartIngestionJob`;
- use deterministic document identifiers for idempotency;
- delete both the Bedrock document and its S3 objects when removing tenant data;
- retain periodic reconciliation syncs only as an operator workflow.

Direct ingestion improves latency and avoids scanning unrelated accounts. It
does not replace the mandatory retrieval account filter.

## Rails Data Model

Use `Account` as the ownership root:

```ruby
class Account < ApplicationRecord
  has_many :users, dependent: :restrict_with_error
  has_many :kb_documents, dependent: :restrict_with_error
  has_many :conversation_sessions, dependent: :destroy
  has_many :bedrock_queries, dependent: :destroy
  # display_name (string, NOT NULL) — title, footer, logo alt
  # branded (boolean) — when true, static assets under accounts/<slug>/
end
```

Add `account_id NOT NULL` to at least:

- `users`
- `kb_documents`
- `kb_document_thumbnails` through their parent document
- `conversation_sessions`
- `technician_documents`
- `bedrock_queries`
- `bulk_uploads`
- `bulk_upload_assets` through their parent upload
- tenant-facing cost or usage rollups

Uniqueness must include account ownership where the value is tenant-local:

```ruby
add_index :kb_documents, [:account_id, :s3_key], unique: true
add_index :conversation_sessions, [:account_id, :identifier, :channel], unique: true
add_index :bedrock_queries, [:account_id, :created_at]
```

Avoid unqualified `find`, `find_by`, and `order` calls on tenant-owned models.
Resolve through the account association:

```ruby
Current.account.kb_documents.find(params[:id])
```

Database row-level security can be added as defense in depth, but it does not
replace explicit application scoping.

## Request and Job Context

**Host resolution (live):** `ApplicationController#host_account` resolves the
tenant from `request.host` via `AccountHostResolver` before auth. Unauthenticated
surfaces (Devise login) already use host-scoped branding through
`AccountBranding`.

The authenticated user determines the account for data access:

```ruby
Current.account = current_user.account
```

Do not trust a browser-provided account ID to select another account. Admin
cross-account access must use an explicit authorization path and audit log.

Jobs must serialize `account_id`:

```ruby
UploadAndSyncAttachmentsJob.perform_later(
  account_id: Current.account.id,
  ...
)
```

The job must fail if the account no longer exists or is inactive. It must not
fall back to a global account or the first available Bedrock data source.

## S3 Authorization

Application code constructs keys from the authenticated account:

```text
uploads/<account_id>/<document_id>/...
bulk_chunks/<account_id>/<document_id>/...
```

Presigned URLs are created only after loading the `KbDocument` through the
current account. Never presign an arbitrary key supplied by request parameters.

The standard SaaS offering uses the shared bucket with account-scoped keys. An
isolated customer may use a dedicated source bucket and a dedicated Knowledge
Base backed by its own Amazon S3 Vectors vector bucket and index. It does not
receive a dedicated Aurora database.

## Caches, Streams, and Metrics

All tenant-visible keys and channels include the account:

```text
account:<account_id>:kb_ingestion_info
account:<account_id>:kb_sync
account:<account_id>:dashboard_metrics
```

This applies to:

- Solid Cache keys;
- Turbo/Action Cable stream names;
- ingestion progress;
- session state;
- document lists;
- usage and cost dashboards;
- deduplication lookups.

Content SHA dedup may share parse work internally, but it must never share
document ownership, aliases, visibility, or source URIs across accounts.

## Rollout Gate

Do not enable a second customer account until all of these pass:

1. Tenant A cannot retrieve Tenant B chunks with unpinned, pinned, fallback, or
   deterministic retrieval paths.
2. Tenant A cannot list, resolve, pin, download, presign, update, or delete
   Tenant B documents by guessing IDs or S3 keys.
3. Jobs, cache entries, Turbo streams, and dashboards are account-scoped.
4. Every indexed chunk has `account_id` and `document_id`.
5. Retrieval fails closed when account metadata or context is missing.
6. Deleting an account removes or tombstones its Rails rows, S3 objects, and
   Bedrock documents without affecting other accounts.
7. Regression tests cover two accounts with intentionally similar filenames,
   aliases, and document content.

## AWS Constraints

The design accounts for these Bedrock quotas:

- maximum five data sources per Knowledge Base;
- one concurrent ingestion job per Knowledge Base;
- one concurrent ingestion job per data source;
- direct ingestion accepts up to 25 documents per request.

The five-data-source limit is a direct reason for the shared data source design.
Adding an account must not consume another data source slot. A dedicated
isolated-customer Knowledge Base has its own data source capacity, but belongs
to the separately priced S3 Vectors isolation offering.

Verify quotas before launch because AWS can revise service limits:

- [Amazon Bedrock quotas](https://docs.aws.amazon.com/general/latest/gr/bedrock.html)
- [Direct ingestion](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-direct-ingestion.html)
- [Metadata filtering](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html)
- [Knowledge Base vector store setup, including Amazon S3 Vectors](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-setup.html)
