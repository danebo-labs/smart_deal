# frozen_string_literal: true

# SQLite silently accepted values beyond precision 12, scale 6.
# PostgreSQL enforces it — s3_total_size in bytes can exceed 999_999.
# Increase to precision 20, scale 6 to handle byte counts up to ~999 TB.
class IncreaseCostMetricsValuePrecision < ActiveRecord::Migration[8.1]
  def up
    change_column :cost_metrics, :value, :decimal, precision: 20, scale: 6, null: false
  end

  def down
    change_column :cost_metrics, :value, :decimal, precision: 12, scale: 6, null: false
  end
end
