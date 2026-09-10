# frozen_string_literal: true

# "Mis informes": a certifier's own certification report drafts (Fase 2 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md). Ownership is by
# user_id, not just account — reports are not shared inside an account at
# this stage (fixed rule 12), so every lookup goes through `owned_reports`.
class CertificationReportsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard
  include CertifierExportRedirect

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  BUILDING_ATTRIBUTES = %i[
    building_name commune street street_number property_use
    municipal_reception_date internal_number inspection_date
    maintenance_company maintenance_technician
  ].freeze

  # Fase 1A: optional data the certifier types while reviewing. `result` is in
  # this list because only a human ever sends it — Danebo never derives it from
  # the registered defects (fixed rule 1).
  REVIEW_ATTRIBUTES = %i[
    inspector_name report_date normative_reference result result_note
  ].freeze

  # No counter cache on inspection_findings (Fase 0 decision): includes here
  # keeps the finding count/thumbnail-eligibility check to one extra query
  # total, not one per report.
  def index
    @reports = owned_reports.recent_first.includes(:inspection_findings)
  end

  def show
    @report = owned_reports.find(params[:id])
    @findings = @report.inspection_findings.includes(:field_photo, :report_equipment)
    @finding = @report.inspection_findings.new
    @equipments = @report.report_equipments.ordered
    @equipment = @report.report_equipments.new
    # Fase 5: reopening a report shows every dictation still awaiting the
    # certifier, with its state (fixed rule 11). The finding a confirmation
    # just created is highlighted with its inline undo for this one render.
    @dictations = @report.voice_dictations.awaiting_certifier
    @highlight_finding_id = flash[:highlight_finding_id]
  end

  # Fase 1B: "Revisar informe" — read-only document view, fixed section order,
  # built from the same partial the future PDF job (Fase 3A) will render from
  # a snapshot. The controller assembles an explicit data set (@export_document)
  # so the partial itself never calls current_account/current_user/request.
  def export
    @report = owned_reports.find(params[:id])
    findings = @report.inspection_findings.includes(:field_photo, :report_equipment)
    equipments = @report.report_equipments.ordered

    @export_document = {
      report: @report,
      issuer: export_issuer_data,
      report_edit_url: edit_certification_report_path(@report, return_to: "export"),
      equipment_rows: export_equipment_rows(equipments),
      finding_rows: export_finding_rows(findings)
    }
  end

  def new
    @report = CertificationReport.new
  end

  def edit
    @report = owned_reports.find(params[:id])
  end

  def create
    @report = CertificationReport.new(building_params)
    @report.account = current_account
    @report.user = current_user

    if @report.save
      redirect_to certification_report_path(@report), notice: t("certifier.notices.report_created")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    @report = owned_reports.find(params[:id])

    if @report.update(report_params)
      redirect_to export_return_path(@report) || certification_report_path(@report),
                  notice: t("certifier.notices.report_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ArgumentError
    @report.errors.add(invalid_enum_attribute, :inclusion)
    render :edit, status: :unprocessable_entity
  end

  def destroy
    # Destroying a report cascades to its findings (dependent: :destroy),
    # which frees any attached evidence photo for FieldPhotoRetentionJob —
    # correct behavior, called out explicitly in the flash copy.
    owned_reports.find(params[:id]).destroy!
    redirect_to certification_reports_path, notice: t("certifier.notices.report_destroyed")
  end

  private

  def owned_reports
    CertificationReport.owned_by(account_id: current_account.id, user_id: current_user.id)
  end

  def building_params
    params.expect(certification_report: [ *BUILDING_ATTRIBUTES ])
  end

  def report_params
    params.expect(certification_report: [ *BUILDING_ATTRIBUTES, *REVIEW_ATTRIBUTES, :status ])
  end

  # Rails enums raise on assignment, not on validation, so an out-of-range
  # value never reaches `save` and the normal 422 path cannot see it. Both
  # `status` and `result` are enums on the same form, so name the offending one
  # instead of always blaming status.
  def invalid_enum_attribute
    submitted_result = params.dig(:certification_report, :result)
    return :result if submitted_result.present? && CertificationReport::RESULTS.keys.map(&:to_s).exclude?(submitted_result)

    :status
  end

  def not_found
    head :not_found
  end

  # Explicit data contract for the review document (Fase 1B). Everything here
  # is a plain value the future PDF job can reconstruct from a snapshot
  # instead of current_account — see the Fase 3A insumos in the plan for the
  # logo/photo resolution strategy a session-less job needs instead.
  def export_issuer_data
    {
      name: current_account.certifier_name,
      minvu_role: current_account.certifier_minvu_role,
      identified: current_account.certifier_identified?,
      logo_url: current_account.certifier_logo? ? logo_certifier_settings_path : nil
    }
  end

  def export_equipment_rows(equipments)
    equipments.map do |equipment|
      { equipment: equipment, edit_url: edit_report_equipment_path(equipment, return_to: "export") }
    end
  end

  # Stable "H-<n>" references (position order) connect the defect tables to the
  # evidence section within this render — not a persisted identifier. Photo
  # URLs are resolved once here, never inside the shared partial, and only kept
  # if they pass the same single "is this our bucket" check every other photo
  # redirect in the app uses.
  def export_finding_rows(findings)
    photo_url_service = FieldPhotoUrlService.new(account: current_account)

    findings.each_with_index.map do |finding, index|
      {
        finding: finding,
        reference: t("certifier.export.finding_reference", number: index + 1),
        photo_url: finding.field_photo && export_trusted_photo_url(photo_url_service, finding.field_photo),
        edit_url: edit_inspection_finding_path(finding, return_to: "export")
      }
    end
  end

  def export_trusted_photo_url(service, photo)
    url = service.call(photo)
    url if service.trusted_redirect_url?(url)
  end
end
