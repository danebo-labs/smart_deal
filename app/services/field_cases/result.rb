# frozen_string_literal: true

module FieldCases
  # Outcome of a history operation. :lost means the row already has a winner
  # and this attempt did not write.
  class Result
    attr_reader :status, :field_case, :turn, :error, :payload, :created

    def initialize(status, field_case: nil, turn: nil, error: nil, payload: nil, created: false)
      @status = status
      @field_case = field_case
      @turn = turn
      @error = error
      @payload = payload
      @created = created
    end

    def disabled? = status == :disabled
    def not_found? = status == :not_found
    def ok? = status == :ok
    def conflict? = status == :conflict
    def invalid? = status == :invalid
    def lost? = status == :lost
    def created? = created
  end
end
