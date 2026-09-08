# frozen_string_literal: true

# Findings of a certification report draft (Fase 2). Ownership is inherited
# from the parent report, never checked on InspectionFinding directly: a
# finding scoped to a report the current user doesn't own must 404 on both
# isolation axes (cross-account and cross-user, fixed rule 12), exactly like
# the report itself.
class InspectionFindingsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def edit
    @finding = owned_finding
    @report = @finding.certification_report
  end

  def create
    report = owned_reports.find(params[:certification_report_id])
    @finding = report.inspection_findings.new(finding_params)
    attach_photo(@finding)

    if @finding.save
      redirect_to certification_report_path(report), notice: t("certifier.notices.finding_created")
    else
      render_report_with_errors(report)
    end
  end

  def update
    @finding = owned_finding
    attach_photo(@finding)

    if @finding.update(finding_params)
      redirect_to certification_report_path(@finding.certification_report), notice: t("certifier.notices.finding_updated")
    else
      @report = @finding.certification_report
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    finding = owned_finding
    report = finding.certification_report
    finding.destroy!
    redirect_to certification_report_path(report), notice: t("certifier.notices.finding_destroyed")
  end

  private

  def owned_reports
    CertificationReport.owned_by(account_id: current_account.id, user_id: current_user.id)
  end

  # Single query: only findings whose report is in the current user's owned
  # scope. Wrong id, another account's report, or another user's report in
  # the same account all resolve the same way — RecordNotFound → 404.
  def owned_finding
    InspectionFinding.where(certification_report_id: owned_reports.select(:id)).find(params[:id])
  end

  def finding_params
    params.expect(inspection_finding: [ :body, :location ])
  end

  # The photo is looked up/created scoped to current_account — the model
  # validation that it matches the report's account is a backstop, not the
  # only guard (plan section 2.2, Fase 2 insumos).
  def attach_photo(finding)
    upload = params.dig(:inspection_finding, :photo)
    return if upload.blank?

    photo = InspectionFindingPhotoAttacher.call(upload, account_id: current_account.id, user_id: current_user.id)
    finding.field_photo = photo if photo
  end

  def render_report_with_errors(report)
    @report = report
    @findings = report.inspection_findings.includes(:field_photo)
    render "certification_reports/show", status: :unprocessable_entity
  end

  def not_found
    head :not_found
  end
end
