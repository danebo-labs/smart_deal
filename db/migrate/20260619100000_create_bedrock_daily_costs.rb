# frozen_string_literal: true

class CreateBedrockDailyCosts < ActiveRecord::Migration[8.1]
  def change
    create_table :bedrock_daily_costs do |t|
      t.date     :utc_date,           null: false
      t.string   :model_id,           null: false
      t.integer  :invocation_count,   null: false, default: 0
      t.bigint   :input_tokens,       null: false, default: 0
      t.bigint   :output_tokens,      null: false, default: 0
      t.bigint   :cache_read_tokens,  null: false, default: 0
      t.bigint   :cache_write_tokens, null: false, default: 0
      t.decimal  :cost_usd, precision: 20, scale: 6, null: false, default: 0
      t.datetime :reconciled_at,      null: false
      t.timestamps
    end
    add_index :bedrock_daily_costs, %i[utc_date model_id], unique: true
    add_index :bedrock_daily_costs, :utc_date
  end
end
