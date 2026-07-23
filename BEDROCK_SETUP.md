# AWS Bedrock Configuration

## Requirements

1. **AWS credentials:** `access_key_id` and `secret_access_key`, or a Bedrock API key / bearer token generated in the AWS console.
2. **Region:** `us-east-1` by default.
3. **Inference Profile:** `global.anthropic.claude-haiku-4-5-20251001-v1:0`,
   the current application default and production setting. Use a `us.` profile
   only when US-only routing is a customer requirement.

## Credentials

### Option 1: Rails Credentials (recommended)

1. Run:
   ```bash
   bin/rails credentials:edit
   ```

2. Add:
   ```yaml
   aws:
     access_key_id: YOUR_AWS_ACCESS_KEY_ID
     secret_access_key: YOUR_AWS_SECRET_ACCESS_KEY
     region: us-east-1
     bedrock_bearer_token: YOUR_AWS_BEDROCK_BEARER_TOKEN (optional)
     bedrock_model_id: global.anthropic.claude-haiku-4-5-20251001-v1:0

   bedrock:
     knowledge_base_id: YOUR_KNOWLEDGE_BASE_ID
     data_source_id: YOUR_DATA_SOURCE_ID (optional)
   ```

3. Save the file.

### Option 2: Environment Variables

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_REGION=us-east-1
export BEDROCK_KNOWLEDGE_BASE_ID=your_kb_id
export BEDROCK_BULK_DATA_SOURCE_ID=your_bulk_no_chunking_data_source_id
```

### Option 3: Bedrock API Key / Bearer Token

If you generated a Bedrock API key in the console:

```bash
export AWS_BEARER_TOKEN_BEDROCK=your_generated_api_key
export AWS_REGION=us-east-1
```

> **Important:** Bedrock keys can expire, for example after 24 hours. Generate a new key and update the environment variable when that happens.

## Knowledge Base Configuration

The app uses AWS Bedrock Knowledge Bases for RAG (Retrieval-Augmented Generation).

### Required Variables

```bash
BEDROCK_KNOWLEDGE_BASE_ID=your_kb_id
BEDROCK_BULK_DATA_SOURCE_ID=your_bulk_no_chunking_data_source_id
KNOWLEDGE_BASE_S3_BUCKET=your-bucket-name
```

### RAG retrieve_and_generate (optional)

Retrieval and generation parameters. Defaults are tuned for safety-critical domains such as elevator field support. In multi-tenant mode, each tenant can override them through `bedrock_config.rag_config`.

| Variable | Default | Description |
|----------|---------|-------------|
| `BEDROCK_RAG_NUMBER_OF_RESULTS` | 10 | Chunks retrieved before reranking |
| `BEDROCK_RAG_SEARCH_TYPE` | HYBRID | HYBRID (semantic + keyword) or SEMANTIC |
| `BEDROCK_RAG_GENERATION_TEMPERATURE` | 0.1 | Favor documentary consistency over creative synthesis |
| `BEDROCK_RAG_GENERATION_MAX_TOKENS` | 3000 | Maximum output tokens |
| `BEDROCK_RERANKER_ENABLED` | false | Experimental Cohere reranking for exhaustive queries only. Keep disabled until it passes the documented RAG quality gate. |

```bash
# Optional example matching the current service defaults.
BEDROCK_RAG_NUMBER_OF_RESULTS=10
BEDROCK_RAG_SEARCH_TYPE=HYBRID
BEDROCK_RAG_GENERATION_TEMPERATURE=0.1
```

**Current data source note:** production IDs live in `config/deploy.yml` and should not be copied into committed templates or local sample files.

### Data Source Selection

- Web and bulk uploads use `BEDROCK_BULK_DATA_SOURCE_ID`, a shared S3 data
  source for app-generated chunks.
- `BEDROCK_DATA_SOURCE_ID` is legacy and only remains as a fallback in older operator tasks/services.
- If the legacy data source is missing or invalid, those older paths use the first available data source.
- To list available data sources, run:

```bash
bin/rails kb:status
```

The command shows:
- The current Knowledge Base ID
- The preferred Data Source ID, when configured
- All available data sources and their details

### Required S3 Data Source Configuration

The active data source must use this exact ingestion contract:

| Setting | Required value |
|---------|----------------|
| Source type | Amazon S3 |
| S3 URI / inclusion prefix | `s3://<KNOWLEDGE_BASE_S3_BUCKET>/bulk_chunks/` |
| Chunking strategy | **No chunking** (`NONE`) |
| Data deletion policy | `DELETE` |

The bucket deliberately contains objects with different responsibilities:

| S3 prefix | Purpose | Indexed by Bedrock |
|-----------|---------|---------------------|
| `bulk_chunks/` | App-generated `.txt` chunks and adjacent `.metadata.json` sidecars | Yes |
| `uploads/` | Original web/chat files used for display, download, audit, and source identity | No |
| `bulk_uploads/` | Original files extracted from bulk ZIP uploads | No |
| `bulk_upload_archives/` | Temporary uploaded ZIP archives | No |

`BatchResultsParserService` has already parsed the originals and written
retrieval-ready text under `bulk_chunks/`. Allowing the data source to scan the
whole bucket causes Bedrock to process originals again, which can:

- emit `Ignored ... file format was not supported` warnings for image originals
  on the text/no-chunking data source;
- index original PDFs alongside app-generated chunks, creating duplicate
  retrieval evidence;
- increase sync work and make ingestion statistics misleading.

The original S3 objects must remain in place. The inclusion prefix controls only
what Bedrock indexes; it does not delete objects from S3.

#### AWS Console

In **Bedrock → Knowledge bases → Data source**, configure the S3 URI as:

```text
s3://<bucket>/bulk_chunks/
```

After changing the prefix, run **Sync** once. With deletion policy `DELETE`,
Bedrock removes previously indexed objects outside `bulk_chunks/` from the
vector index. It does not remove them from S3.

Expected sync result:

- status `Complete`;
- failed documents `0`;
- scanned source documents match the chunk `.txt` objects;
- metadata documents match their adjacent `.metadata.json` files.

#### AWS CLI verification

```bash
aws bedrock-agent get-data-source \
  --knowledge-base-id "$BEDROCK_KNOWLEDGE_BASE_ID" \
  --data-source-id "$BEDROCK_BULK_DATA_SOURCE_ID" \
  --region "${AWS_REGION:-us-east-1}" \
  --query 'dataSource.{status:status,s3:dataSourceConfiguration.s3Configuration,chunking:vectorIngestionConfiguration.chunkingConfiguration}'
```

The response must contain:

```json
{
  "s3": {
    "bucketArn": "arn:aws:s3:::YOUR_BUCKET",
    "inclusionPrefixes": ["bulk_chunks/"]
  },
  "chunking": {
    "chunkingStrategy": "NONE"
  }
}
```

Start and inspect a sync:

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$BEDROCK_KNOWLEDGE_BASE_ID" \
  --data-source-id "$BEDROCK_BULK_DATA_SOURCE_ID" \
  --region "${AWS_REGION:-us-east-1}"

aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id "$BEDROCK_KNOWLEDGE_BASE_ID" \
  --data-source-id "$BEDROCK_BULK_DATA_SOURCE_ID" \
  --max-results 1 \
  --sort-by attribute=STARTED_AT,order=DESCENDING \
  --region "${AWS_REGION:-us-east-1}"
```

### Multi-Tenant Evolution

The inclusion prefix is not a tenant boundary. The planned SaaS topology keeps
one Knowledge Base, one S3 data source, and one Aurora/pgvector store shared
across accounts.

AWS currently allows a maximum of five data sources per Knowledge Base. This is
a Knowledge Base capacity constraint, not a tenant-isolation mechanism.
Consequently:

- never allocate one data source per account;
- reserve data sources for genuinely different shared ingestion contracts;
- keep all standard customer chunks in the shared `bulk_chunks/` data source;
- use `account_id` metadata filters, not data source IDs, for tenant isolation.

Do not create an Aurora vector store per tenant. If a customer contract requires
physical vector-store isolation, provision a dedicated Knowledge Base backed by
a dedicated Amazon S3 Vectors vector bucket and index. Validate latency and
query volume for that tier because S3 Vectors is intended primarily for
cost-effective, infrequent-query workloads.

When multi-tenancy is implemented:

- keep the data source inclusion prefix as `bulk_chunks/`;
- store chunks under
  `bulk_chunks/<account_id>/<document_id>/chunk_N.txt`;
- write `account_id` and `document_id` into every chunk sidecar;
- apply an `account_id` metadata filter to every Retrieve and
  RetrieveAndGenerate request;
- fail closed when account context is missing;
- never remove the account filter during no-results fallback;
- scope app records, S3 access, presigned URLs, caches, broadcasts, and metrics
  by the same account.

See [docs/MULTI_TENANT_ARCHITECTURE.md](docs/MULTI_TENANT_ARCHITECTURE.md) for
the complete isolation contract.

### Embedding Model

The embedding model is configured **in AWS when the Knowledge Base is created**, not in the app. The current KB uses `amazon.titan-embed-text-v2:0` with `1024` dimensions. The `.env` variable `BEDROCK_EMBEDDING_MODEL_ID` is only a UI reference; it does not affect KB behavior.

To see which embedding model your Knowledge Base uses:

```bash
bin/rails kb:embedding_model
```

Requires IAM permission `bedrock:GetKnowledgeBase` on the Knowledge Base ARN.

**Important:** the embedding model cannot be changed on an existing KB. `embeddingModelArn` is immutable. To use another model, create a new Knowledge Base and re-index the documents. Existing embeddings are not overwritten because each model produces vectors with different dimensions.

### Vision Model (for chat image attachments)

The **vision model** is the LLM that analyzes images attached by the user in chat. It is separate from the embedding model:

| Concept | Use | Configuration |
|---------|-----|---------------|
| **Embedding** | Converts text to vectors for KB semantic search | AWS Knowledge Base creation (Nova multimodal, Cohere, etc.) |
| **Vision** | Processes images attached in chat | `BEDROCK_VISION_MODEL_ID` in `.env` |

Haiku does not support images. When the user attaches a photo and the default model is Haiku, the app automatically uses the vision model. Optional configuration:

```bash
BEDROCK_VISION_MODEL_ID=global.anthropic.claude-sonnet-4-6
```

## AI Provider Configuration

**Note:** only AWS Bedrock is currently supported. Other providers (OpenAI, Anthropic, GEIA) were removed because they were unused.

### `AI_PROVIDER` environment variable

Bedrock is the default:

```bash
# AWS Bedrock is the only available provider.
export AI_PROVIDER=bedrock
```

### Rails Credentials

You can also configure it with `bin/rails credentials:edit`:

```yaml
aws:
  access_key_id: YOUR_ACCESS_KEY
  secret_access_key: YOUR_SECRET_KEY
  region: us-east-1
  bedrock_bearer_token: YOUR_BEDROCK_BEARER_TOKEN (if applicable)
  bedrock_model_id: global.anthropic.claude-haiku-4-5-20251001-v1:0

bedrock:
  knowledge_base_id: YOUR_KNOWLEDGE_BASE_ID
  data_source_id: YOUR_DATA_SOURCE_ID (optional)

# AI provider configuration (Bedrock only).
ai_provider: bedrock
```

## Testing the Integration

### 1. Upload a PDF

Go to `http://localhost:3000` and upload a PDF. The system processes the document with Bedrock automatically.

### 2. REST API endpoint for RAG (Knowledge Base)

You can query the Knowledge Base directly:

```bash
curl -X POST http://localhost:3000/rag/ask \
  -H "Content-Type: application/json" \
  -H "Cookie: [your_session_cookie]" \
  -d '{
    "question": "What is S3?"
  }'
```

**Note:** the `/ai/ask` endpoint was removed. To process documents, use the web UI or the `/documents/process` endpoint.

## Service Structure

The app uses these services:

- `app/services/bedrock_client.rb` - AWS Bedrock client
- `app/services/bedrock_rag_service.rb` - RAG service for Knowledge Base queries
- `app/services/ai_provider.rb` - Facade using `BedrockClient`; Bedrock is the only provider

## Verification

1. Verify that credentials are configured:
   ```bash
   bin/rails runner "puts Rails.application.credentials.dig(:aws, :access_key_id) ? 'OK' : 'NOT CONFIGURED'"
   ```

2. Verify the active provider:
   ```bash
   bin/rails runner "puts ENV.fetch('AI_PROVIDER', 'bedrock')"
   ```

3. Restart the Rails server after changing credentials:
   ```bash
   bin/dev
   ```

## IAM Permissions for the Application User

The AWS credentials used by the app, for example `bedrock-integration-user`, need these permissions for RAG:

| Action | Resource | Reason |
|--------|----------|--------|
| `bedrock:RetrieveAndGenerate` | Knowledge Base | Query the Knowledge Base through the API |
| `bedrock:Retrieve` | Knowledge Base | Vector retrieval, used internally by RetrieveAndGenerate |
| `bedrock:Rerank` | `*` | Optional result reranking. AWS does not expose resource-level scoping for this action. |
| `bedrock:InvokeModel` | Foundation models | Generate Claude answers |
| `bedrock:GetKnowledgeBase` | Knowledge Base | Optional; used by `bin/rails kb:embedding_model` |

**Minimum IAM policy for the application user** (replace `YOUR_ACCOUNT_ID` and `YOUR_KB_ID`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RetrieveAndRetrieveAndGenerate",
      "Effect": "Allow",
      "Action": [
        "bedrock:Retrieve",
        "bedrock:RetrieveAndGenerate",
        "bedrock:GetKnowledgeBase"
      ],
      "Resource": "arn:aws:bedrock:us-east-1:YOUR_ACCOUNT_ID:knowledge-base/YOUR_KB_ID"
    },
    {
      "Sid": "Rerank",
      "Effect": "Allow",
      "Action": "bedrock:Rerank",
      "Resource": "*"
    },
    {
      "Sid": "InvokeModel",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": [
        "arn:aws:bedrock:us-east-1:YOUR_ACCOUNT_ID:inference-profile/global.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/us.anthropic.claude-haiku-4-5-20251001-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/*"
      ]
    }
  ]
}
```

For multiple Knowledge Bases, use `arn:aws:bedrock:us-east-1:YOUR_ACCOUNT_ID:knowledge-base/*`.

`bedrock:Rerank` is intentionally shown with `"Resource": "*"` because the AWS
service authorization reference does not define a resource type for that action.
The application still selects the fixed Cohere Rerank v3.5 model ARN in code.
Reranking is disabled by default after the
[2026-06-09 quality benchmark](docs/RAG_QUALITY_BENCHMARK_2026-06-09.md) found
that reducing 15 candidates to 9 or 12 omitted functional-test evidence.

See `docs/bedrock-iam-policy.json` for the repository policy reference.

## Troubleshooting

### Error: "is not authorized to perform: bedrock:RetrieveAndGenerate" or "bedrock:Retrieve"

- The IAM user, for example `bedrock-integration-user`, does not have `bedrock:RetrieveAndGenerate` or `bedrock:Retrieve`.
- **Fix:** add the policy from "IAM Permissions for the Application User" to the user in IAM → Users → your user → Add permissions → Create inline policy.

### Error: "is not authorized to perform: bedrock:GetKnowledgeBase"

- Appears when running `bin/rails kb:embedding_model`.
- **Fix:** add `bedrock:GetKnowledgeBase` to the Knowledge Base statement in the IAM policy above.

### Error: "Unknown AI provider"

- Only `bedrock` is available. Verify that `AI_PROVIDER` is `bedrock` or unset; unset defaults to Bedrock.

### Error: "Bedrock error: AccessDeniedException"

- Verify that your AWS credentials have Bedrock permissions.
- Verify that the model is enabled in your AWS region.

### Error: "Bedrock error: ... inference profile"

- Verify that `BEDROCK_MODEL_ID` points to a valid inference profile. The current
  default is `global.anthropic.claude-haiku-4-5-20251001-v1:0`.
- The `us.` prefix restricts routing to US regions; choose it for a validated
  residency requirement, not as the repository default.

### Error: "API key not configured"

- Verify that credentials are present in Rails credentials or environment variables.
- Restart the server after changing credentials.
