# frozen_string_literal: true

# "Mis informes": a certifier's own certification report drafts (Fase 2 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md). Ownership is by
# user_id, not just account — reports are not shared inside an account at
# this stage (fixed rule 12), so every lookup goes through `owned_reports`.
class CertificationReportsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  BUILDING_ATTRIBUTES = %i[
    building_name commune street street_number property_use
    municipal_reception_date internal_number inspection_date
    maintenance_company maintenance_technician
  ].freeze

  # No counter cache on inspection_findings (Fase 0 decision): includes here
  # keeps the finding count/thumbnail-eligibility check to one extra query
  # total, not one per report.
  def index
    @reports = owned_reports.recent_first.includes(:inspection_findings)
  end

  def show
    @report = owned_reports.find(params[:id])
    @findings = @report.inspection_findings.includes(:field_photo)
    @finding = @report.inspection_findings.new
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
      redirect_to certification_report_path(@report), notice: t("certifier.notices.report_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  rescue ArgumentError
    @report.errors.add(:status, :inclusion)
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
    params.expect(certification_report: [ *BUILDING_ATTRIBUTES, :status ])
  end

  def not_found
    head :not_found
  end
end
