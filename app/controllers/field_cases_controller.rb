# frozen_string_literal: true

# Create and read a technician's cases. Chat submissions enter via RagController.
class FieldCasesController < ApplicationController
  include AuthenticationConcern

  before_action :private_history
  include FieldCaseHistoryGuard

  def index
    render_result FieldCases::Read.list(
      account: current_account,
      user: current_user,
      cursor: params[:cursor],
      limit: params[:limit]
    )
  end

  def show
    render_result FieldCases::Read.fetch(
      account: current_account,
      user: current_user,
      field_case_id: params[:id],
      after_sequence: params[:after_sequence],
      limit: params[:limit]
    )
  end

  def turn
    render_result FieldCases::Read.turn(
      account: current_account,
      user: current_user,
      field_case_id: params[:id],
      turn_id: params[:turn_id]
    )
  end

  def create
    if params.key?(:document_focus) || params.key?(:pins)
      return render json: { "error" => "pins_not_accepted" }, status: :unprocessable_entity
    end

    result = FieldCases::Create.call(
      account: current_account,
      user: current_user,
      creation_key: params[:creation_key]
    )
    render_result result, success: result.created? ? :created : :ok
  end

  private

  def private_history
    response.set_header("Cache-Control", "private, no-store")
  end

  def render_result(result, success: :ok)
    return head :not_found if result.disabled? || result.not_found?
    return render json: { "error" => result.error.to_s }, status: :unprocessable_entity if result.invalid?
    return render json: { "error" => result.error.to_s }, status: :conflict if result.conflict? || result.lost?

    render json: result.payload, status: success
  end
end
