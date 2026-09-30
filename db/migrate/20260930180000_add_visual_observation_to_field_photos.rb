# frozen_string_literal: true

class AddVisualObservationToFieldPhotos < ActiveRecord::Migration[8.1]
  def change
    add_column :field_photos, :visual_observation, :jsonb
  end
end
