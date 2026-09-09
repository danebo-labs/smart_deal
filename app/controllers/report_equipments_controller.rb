# frozen_string_literal: true

# The elevators of a report draft (Fase 1A). Ownership is inherited from the
# parent report and never checked on ReportEquipment directly, exactly like
# InspectionFindingsController: another account's report and another user's
# report in the same account both 404 (fixed rule 12).
#
# Creating one asks for the visible label only — minimal typing during capture.
# The optional technical characteristics of section 3.1 are revealed on edit.
class ReportEquipmentsController < ApplicationController
  include AuthenticationConcern
  include CertifierModuleGuard

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  SPEC_ATTRIBUTES = %i[
    label position machine_room drive_type door_type boardings_count
    landings_count traction_cables speed_mps rated_load_kg capacity_persons
    last_maintenance_date
  ].freeze

  def edit
    @equipment = owned_equipment
    @report    = @equipment.certification_report
  end

  def create
    report = owned_reports.find(params[:certification_report_id])
    equipment = report.report_equipments.new(equipment_params)
    # The column defaults to 0, so the attribute is never blank — the submitted
    # params are what decide whether the certifier chose an order.
    equipment.position = next_position(report) if params.dig(:report_equipment, :position).blank?

    if equipment.save
      redirect_to certification_report_path(report), notice: t("certifier.notices.equipment_created")
    else
      @equipment_errors = equipment
      render_report_with_errors(report)
    end
  end

  def update
    @equipment = owned_equipment

    if @equipment.update(equipment_params)
      redirect_to certification_report_path(@equipment.certification_report),
                  notice: t("certifier.notices.equipment_updated")
    else
      @report = @equipment.certification_report
      render :edit, status: :unprocessable_entity
    end
  end

  # Findings are never destroyed as a side effect of removing an equipment: the
  # restrictive foreign key and the restrict_with_error association both refuse,
  # and the certifier is told to reassign them first.
  def destroy
    equipment = owned_equipment
    report    = equipment.certification_report

    if equipment.destroy
      redirect_to certification_report_path(report), notice: t("certifier.notices.equipment_destroyed")
    else
      redirect_to certification_report_path(report), alert: t("certifier.equipment.alerts.has_findings")
    end
  end

  private

  def owned_reports
    CertificationReport.owned_by(account_id: current_account.id, user_id: current_user.id)
  end

  def owned_equipment
    ReportEquipment.where(certification_report_id: owned_reports.select(:id)).find(params[:id])
  end

  def equipment_params
    params.expect(report_equipment: [ *SPEC_ATTRIBUTES ])
  end

  # Appends at the end so a new elevator does not reshuffle the existing order.
  def next_position(report)
    (report.report_equipments.maximum(:position) || -1) + 1
  end

  def render_report_with_errors(report)
    @report = report
    @findings = report.inspection_findings.includes(:field_photo, :report_equipment)
    @finding = report.inspection_findings.new
    @equipments = report.report_equipments.ordered
    @equipment = @equipment_errors
    @dictations = report.voice_dictations.awaiting_certifier
    render "certification_reports/show", status: :unprocessable_entity
  end

  def not_found
    head :not_found
  end
end
