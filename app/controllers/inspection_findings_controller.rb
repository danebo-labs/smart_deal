# frozen_string_literal: true

# Findings of a certification report draft (Fase 2). Ownership is inherited
# from the parent report, never checked on InspectionFinding directly: a
# finding scoped to a report the current user doesn't own must 404 on both
# isolation axes (cross-account and cross-user, fixed rule 12), exactly like
# the report itself.
class InspectionFindingsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard
  include CertifierExportRedirect

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def edit
    @finding = owned_finding
    @report = @finding.certification_report
    @equipments = @report.report_equipments.ordered
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
      report = @finding.certification_report
      redirect_to export_return_path(report, anchor: dom_id(@finding)) || certification_report_path(report),
                  notice: t("certifier.notices.finding_updated")
    else
      render_edit_with_errors
    end
  rescue ArgumentError
    # `severity` is an enum: an out-of-range value raises on assignment, before
    # any validation runs. 422, not a 500.
    @finding.errors.add(:severity, :inclusion)
    render_edit_with_errors
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

  # Fase 1A adds the certifier's own classification fields. Every one of them is
  # optional and only a human ever submits them (fixed rule 1): Danebo writes
  # none of these on its own, and a blank one stays blank.
  FINDING_ATTRIBUTES = %i[
    body location report_equipment_id inspection_item nch2840_box norm_point
    severity position
  ].freeze

  def finding_params
    params.expect(inspection_finding: [ *FINDING_ATTRIBUTES ]).tap do |attrs|
      # An empty select means "not classified" — nil, never the string "".
      %i[report_equipment_id inspection_item severity].each do |key|
        attrs[key] = nil if attrs.key?(key) && attrs[key].blank?
      end
      # position is NOT NULL: a blank order field means "leave it as it is".
      attrs.delete(:position) if attrs.key?(:position) && attrs[:position].blank?
    end
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

  def render_edit_with_errors
    @report = @finding.certification_report
    @equipments = @report.report_equipments.ordered
    render :edit, status: :unprocessable_entity
  end

  def render_report_with_errors(report)
    @report = report
    @findings = report.inspection_findings.includes(:field_photo, :report_equipment)
    @equipments = report.report_equipments.ordered
    @equipment = report.report_equipments.new
    @dictations = report.voice_dictations.awaiting_certifier
    render "certification_reports/show", status: :unprocessable_entity
  end

  def not_found
    head :not_found
  end
end
