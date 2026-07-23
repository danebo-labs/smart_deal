# frozen_string_literal: true

class AddAttributionToBedrockQueries < ActiveRecord::Migration[8.1]
  def change
    add_column :bedrock_queries, :account_id, :bigint
    add_column :bedrock_queries, :user_id, :bigint
    add_column :bedrock_queries, :conversation_session_id, :bigint

    add_index :bedrock_queries, [ :account_id, :user_id, :created_at ]
  end
end
