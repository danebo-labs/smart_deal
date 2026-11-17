# frozen_string_literal: true

class ScopeCasePhotoStorage < ActiveRecord::Migration[8.1]
  def change
    add_column :field_photos, :storage_scope, :string, null: false, default: ""
    remove_index :field_photos, %i[account_id sha256], unique: true
    add_index :field_photos, %i[account_id sha256 storage_scope], unique: true
  end
end
