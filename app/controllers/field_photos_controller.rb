# frozen_string_literal: true

class FieldPhotosController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    photo = current_account.field_photos.find(params[:id])
    url   = FieldPhotoUrlService.new(account: current_account).call(photo)
    return head :not_found if url.blank?

    redirect_to url, allow_other_host: true
  end

  private

  def not_found
    head :not_found
  end
end
