# frozen_string_literal: true

class ExtendBedrockQueriesForSourceTracking < ActiveRecord::Migration[8.1]
  def change
    add_column :bedrock_queries, :source, :string, default: "query", null: false
    add_index  :bedrock_queries, [ :source, :created_at ]
  end
end
