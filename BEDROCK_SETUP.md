# AWS Bedrock Configuration

## Requirements

1. **AWS credentials:** `access_key_id` and `secret_access_key`, or a Bedrock API key / bearer token generated in the AWS console.
2. **Region:** `us-east-1` by default.
3. **Inference Profile:** `us.anthropic.claude-haiku-4-5-20251001-v1:0`, the US-region profile for Claude Haiku 4.5 (20% cheaper than `global.` with same quality; routes within us-east-1).

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
     bedrock_model_id: us.anthropic.claude-haiku-4-5-20251001-v1:0

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

- Web and bulk uploads should use `BEDROCK_BULK_DATA_SOURCE_ID`, a data source with Bedrock chunking disabled for app-generated chunks.
- `BEDROCK_DATA_SOURCE_ID` is legacy and only remains as a fallback in older operator tasks/services.
- If the legacy data source is missing or invalid, those older paths use the first available data source.
- **No inclusion prefix:** the current data source has no inclusion prefix, so Bedrock indexes the whole bucket. Documents are uploaded under `uploads/{date}/{file}`.
- To list available data sources, run:

```bash
bin/rails kb:status
```

The command shows:
- The current Knowledge Base ID
- The preferred Data Source ID, when configured
- All available data sources and their details

### Embedding Model

The embedding model is configured **in AWS when the Knowledge Base is created**, not in the app. The current KB uses `amazon.nova-2-multimodal-embeddings-v1:0` with `1024` dimensions. The `.env` variable `BEDROCK_EMBEDDING_MODEL_ID` is only a UI reference; it does not affect KB behavior.

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
  bedrock_model_id: us.anthropic.claude-haiku-4-5-20251001-v1:0

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

See `docs/bedrock-app-user-iam-policy.json` for a complete policy ready to attach.

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

- Verify that `BEDROCK_MODEL_ID` points to a valid inference profile. The default is `us.anthropic.claude-haiku-4-5-20251001-v1:0` (US-region Haiku 4.5, 20% cheaper than `global.`).
- The `us.` prefix routes within US regions only. If you work outside us-east-1, use `global.anthropic.claude-haiku-4-5-20251001-v1:0` instead.

### Error: "API key not configured"

- Verify that credentials are present in Rails credentials or environment variables.
- Restart the server after changing credentials.
