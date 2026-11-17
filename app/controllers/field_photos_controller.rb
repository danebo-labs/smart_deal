# frozen_string_literal: true

class FieldPhotosController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def show
    photo   = current_account.field_photos.find(params[:id])
    return head :not_found if photo.storage_scope.present? && photo.user_id != current_user.id

    response.set_header("Cache-Control", "private, no-store") if photo.storage_scope.present?

    service = FieldPhotoUrlService.new(account: current_account)
    url     = service.call(photo)
    return head :not_found unless service.trusted_redirect_url?(url)

    redirect_to url, allow_other_host: true
  end

  private

  def not_found
    head :not_found
  end
end
