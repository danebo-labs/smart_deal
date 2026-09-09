# frozen_string_literal: true

# "Datos de la certificadora": the one issuer identity of a company, configured
# once and used by every report of the account (fixed rule 14). A company is an
# account, so this is a singular resource on current_account — there is no
# per-report variant, no template editor and no theme.
#
# Write access belongs to a single designated user
# (account.certifier_settings_user, assigned by the documented onboarding rake
# task). Everyone else in the company reads the data and uses it in their own
# reports: read-only here is not a 404, because seeing the header that will
# appear on your report is legitimate.
class CertifierSettingsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard

  before_action :require_settings_manager!, only: %i[update destroy_logo]

  def show
    @account  = current_account
    @editable = @account.certifier_settings_manager?(current_user)
    @logo_url = logo_url
  end

  def update
    @account = current_account

    logo_error = attach_logo
    return render_show_with_logo_error(logo_error) if logo_error

    if @account.update(settings_params)
      redirect_to certifier_settings_path, notice: t("certifier.settings.notices.updated")
    else
      @editable = true
      @logo_url = logo_url
      render :show, status: :unprocessable_entity
    end
  end

  # Removing the logo clears this account's reference. It never deletes the S3
  # object: an export already generated may still point at those bytes
  # (fixed rule 15).
  def destroy_logo
    current_account.update!(
      certifier_logo_s3_key: nil, certifier_logo_content_type: nil,
      certifier_logo_byte_size: nil, certifier_logo_sha256: nil
    )
    redirect_to certifier_settings_path, notice: t("certifier.settings.notices.logo_removed")
  end

  # Serves the logo the same way FieldPhotosController serves a photo: redirect
  # to a short-lived presigned URL, and only if it really points at our bucket.
  def logo
    service = CertifierLogoUrlService.new(account: current_account)
    url     = service.call
    return head :not_found unless service.trusted_redirect_url?(url)

    redirect_to url, allow_other_host: true
  end

  private

  def settings_params
    params.expect(account: %i[certifier_name certifier_minvu_role])
  end

  # A rejected logo must leave the previous one in place, so the metadata is
  # only assigned once the store confirms new bytes are durable.
  def attach_logo
    upload = params.dig(:account, :certifier_logo)
    return nil if upload.blank?

    result = CertifierLogoStore.call(upload, account_id: current_account.id)
    return result.error unless result.ok?

    @account.assign_attributes(
      certifier_logo_s3_key: result.s3_key, certifier_logo_content_type: result.content_type,
      certifier_logo_byte_size: result.byte_size, certifier_logo_sha256: result.sha256
    )
    nil
  end

  def render_show_with_logo_error(error)
    @account.reload
    @editable = true
    @logo_url = logo_url
    flash.now[:alert] = t("certifier.settings.logo_errors.#{error}")
    render :show, status: :unprocessable_entity
  end

  def logo_url
    return nil unless @account.certifier_logo?

    logo_certifier_settings_path
  end

  def require_settings_manager!
    return if current_account.certifier_settings_manager?(current_user)

    redirect_to certifier_settings_path, alert: t("certifier.settings.alerts.not_manager")
  end
end
