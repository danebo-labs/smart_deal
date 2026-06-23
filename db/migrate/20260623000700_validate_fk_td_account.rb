# frozen_string_literal: true

class ValidateFkTdAccount < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :technician_documents, name: :fk_td_account
  end

  def down
    # Can't un-validate a FK; would need to re-add with validate: false
  end
end
