# frozen_string_literal: true

# Backfills display_name/branded for the two known accounts by slug (matches
# db/seeds.rb) so this migration is safe to run standalone on any environment.
class AddDisplayNameAndBrandedToAccounts < ActiveRecord::Migration[8.1]
  DISPLAY_NAMES = {
    "danebo-legacy" => "Danebo",
    "elevadores-climb" => "Ascensores Climb"
  }.freeze

  def up
    add_column :accounts, :display_name, :string
    add_column :accounts, :branded, :boolean, default: false, null: false

    DISPLAY_NAMES.each do |slug, name|
      execute("UPDATE accounts SET display_name = #{quote(name)} WHERE slug = #{quote(slug)}")
    end
    execute("UPDATE accounts SET display_name = slug WHERE display_name IS NULL")
    execute("UPDATE accounts SET branded = true WHERE slug = #{quote('elevadores-climb')}")

    change_column_null :accounts, :display_name, false
  end

  def down
    remove_column :accounts, :branded
    remove_column :accounts, :display_name
  end
end
