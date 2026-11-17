# frozen_string_literal: true

module FieldCases
  # Every history read and write starts here: flag, then the host account
  # and the technician who owns the row.
  module Guard
    module_function

    def gate(account:, user:)
      return Result.new(:disabled) unless FieldCaseHistoryFlag.enabled?
      return Result.new(:not_found) unless owner?(account, user)

      nil
    end

    def owner?(account, user)
      account && user && user.account_id == account.id
    end

    def locked_case(account:, user:, field_case_id:)
      FieldCase.lock.find_by(id: field_case_id, account_id: account.id, user_id: user.id)
    end
  end
end
