# frozen_string_literal: true

# Gate 9R B.1 (paso 13): V1 showed the app ledger underestimated query cost by
# 29.7% because Bedrock retrieve_and_generate exposes no usage block and input
# tokens are reconstructed from observable citations only.
#
#   token_source = "provider_usage" — both token counts came from the provider's
#                  usage payload (Anthropic direct/Batch, invoke_model). Exact.
#   token_source = "estimated"      — at least one count was reconstructed via
#                  AnthropicTokenCounter from prompt/answer text (RAG query
#                  rows). NOT invoice truth; commercial reporting must use a
#                  CloudWatch-reconciled basis or label these rows explicitly.
#
# Legacy rows keep NULL (unknown basis).
class AddTokenSourceToBedrockQueries < ActiveRecord::Migration[8.1]
  def change
    add_column :bedrock_queries, :token_source, :string
  end
end
