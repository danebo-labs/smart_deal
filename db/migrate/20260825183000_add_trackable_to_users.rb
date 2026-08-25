# frozen_string_literal: true

# Pilot adoption cannot be read from the web log: the Docker json-file driver runs
# with max-size=10m and no max-file, so sign-in lines rotate away. These are the
# five columns Devise's :trackable maintains, left commented out by the original
# devise generator.
class AddTrackableToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sign_in_count, :integer, default: 0, null: false
    add_column :users, :current_sign_in_at, :datetime
    add_column :users, :last_sign_in_at, :datetime
    add_column :users, :current_sign_in_ip, :string
    add_column :users, :last_sign_in_ip, :string
  end
end
