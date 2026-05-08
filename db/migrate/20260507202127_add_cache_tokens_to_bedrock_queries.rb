# frozen_string_literal: true

class AddCacheTokensToBedrockQueries < ActiveRecord::Migration[8.1]
  def change
    add_column :bedrock_queries, :cache_read_tokens, :integer
    add_column :bedrock_queries, :cache_creation_tokens, :integer
  end
end
