# frozen_string_literal: true

# No DDL change needed — metric_type is a Rails integer enum stored as INTEGER.
# New enum values 20–31 are defined in CostMetric. This migration acts as a
# schema-version marker so deploys know when the new channels became active.
class AddChannelMetricTypes < ActiveRecord::Migration[8.0]
  def change
  end
end
