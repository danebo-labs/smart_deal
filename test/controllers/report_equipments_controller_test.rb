# frozen_string_literal: true

require "test_helper"

# Equipment inherits its ownership from the parent report, so both isolation
# axes apply: another company's report and a colleague's report in the same
# company are equally invisible (fixed rule 12).
class ReportEquipmentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  CLIMB_HOST = "ascensoresclimb.localhost"

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @user    = users(:one)
    @account = accounts(:legacy)
    @report  = certification_reports(:torre_amunategui)
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end

  def other_user_in_legacy
    User.create!(email: "second-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @account)
  end

  # ── Guards ─────────────────────────────────────────────────────────────────

  test "create responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user

    post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "Ascensor A" } }
    assert_response :not_found
  end

  test "redirects an unauthenticated visitor to login" do
    post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "Ascensor A" } }
    assert_response :redirect
  end

  # ── create: label only, minimal typing ─────────────────────────────────────

  test "creates an equipment with just its visible label" do
    sign_in @user

    assert_difference "ReportEquipment.count", 1 do
      post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "Ascensor A" } }
    end

    assert_redirected_to certification_report_path(@report)
    equipment = @report.report_equipments.order(:id).last
    assert_equal "Ascensor A", equipment.label
    assert_equal @account.id, equipment.account_id
    assert_nil equipment.machine_room, "nothing technical may be guessed on create"
  end

  test "appends each new equipment after the existing ones" do
    sign_in @user

    post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "Ascensor A" } }
    post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "Ascensor B" } }

    assert_equal [ 0, 1 ], @report.report_equipments.ordered.pluck(:position)
    assert_equal [ "Ascensor A", "Ascensor B" ], @report.report_equipments.ordered.pluck(:label)
  end

  test "a blank label re-renders the report with the error" do
    sign_in @user

    assert_no_difference "ReportEquipment.count" do
      post certification_report_report_equipments_path(@report), params: { report_equipment: { label: "" } }
    end

    assert_response :unprocessable_entity
    assert_match @report.building_name, response.body
  end

  # ── Isolation, both axes ───────────────────────────────────────────────────

  test "cannot add equipment to a report of another company" do
    sign_in @user
    other = certification_reports(:edificio_portales)

    assert_no_difference "ReportEquipment.count" do
      post certification_report_report_equipments_path(other), params: { report_equipment: { label: "Intruso" } }
    end

    assert_response :not_found
  end

  test "cannot add equipment to a colleague's report in the same company" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "Torre Ajena")

    assert_no_difference "ReportEquipment.count" do
      post certification_report_report_equipments_path(colleague_report), params: { report_equipment: { label: "Intruso" } }
    end

    assert_response :not_found
  end

  test "cannot edit an equipment of another company" do
    sign_in @user

    get edit_report_equipment_path(report_equipments(:climb_ascensor_a))
    assert_response :not_found
  end

  test "cannot update an equipment of another company" do
    sign_in @user
    foreign = report_equipments(:climb_ascensor_a)

    patch report_equipment_path(foreign), params: { report_equipment: { label: "Secuestrado" } }

    assert_response :not_found
    assert_equal "Ascensor A", foreign.reload.label
  end

  test "cannot delete an equipment of another company" do
    sign_in @user

    assert_no_difference "ReportEquipment.count" do
      delete report_equipment_path(report_equipments(:climb_ascensor_b))
    end
    assert_response :not_found
  end

  # ── edit / update: the optional characteristics ─────────────────────────────

  test "the edit form is reachable for an own equipment" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    get edit_report_equipment_path(equipment)

    assert_response :success
    assert_match "Ascensor A", response.body
  end

  test "saves the technical characteristics the certifier typed" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    patch report_equipment_path(equipment), params: {
      report_equipment: {
        label: "Ascensor A", machine_room: "sin_sala", drive_type: "hidraulico",
        landings_count: "8", speed_mps: "0.63", rated_load_kg: "450", capacity_persons: "6",
        door_type: "Automática", traction_cables: "4 x 10 mm", last_maintenance_date: "2026-08-20"
      }
    }

    assert_redirected_to certification_report_path(@report)
    equipment.reload
    assert_equal "sin_sala", equipment.machine_room
    assert_equal "hidraulico", equipment.drive_type
    assert_equal 8, equipment.landings_count
    assert_equal 0.63, equipment.speed_mps.to_f
    assert_equal Date.new(2026, 8, 20), equipment.last_maintenance_date
  end

  test "leaves untouched characteristics blank rather than defaulting them" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    patch report_equipment_path(equipment), params: { report_equipment: { label: "Ascensor A", landings_count: "8" } }

    equipment.reload
    assert_equal 8, equipment.landings_count
    assert_nil equipment.speed_mps
    assert_nil equipment.machine_room
    assert_nil equipment.capacity_persons
  end

  test "an invalid characteristic re-renders the form" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    patch report_equipment_path(equipment), params: { report_equipment: { label: "Ascensor A", machine_room: "quizas" } }

    assert_response :unprocessable_entity
    assert_nil equipment.reload.machine_room
  end

  # ── destroy: findings are never collateral damage ───────────────────────────

  test "deletes an equipment that carries no findings" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    assert_difference "ReportEquipment.count", -1 do
      delete report_equipment_path(equipment)
    end

    assert_redirected_to certification_report_path(@report)
  end

  test "refuses to delete an equipment with findings and says why" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")
    inspection_findings(:pozo_iluminacion).update!(report_equipment: equipment)

    assert_no_difference [ "ReportEquipment.count", "InspectionFinding.count" ] do
      delete report_equipment_path(equipment)
    end

    assert_redirected_to certification_report_path(@report)
    assert_equal I18n.t("certifier.equipment.alerts.has_findings"), flash[:alert]
  end

  # ── Old data ───────────────────────────────────────────────────────────────

  test "a report with no equipment still opens and offers to add one" do
    sign_in @user

    get certification_report_path(@report)

    assert_response :success
    assert_empty @report.report_equipments
    assert_match I18n.t("certifier.equipment.empty"), response.body
  end

  test "the configured company's report lists its equipment" do
    host! CLIMB_HOST
    sign_in users(:two)

    get certification_report_path(certification_reports(:edificio_portales))

    assert_response :success
    assert_match "Ascensor A", response.body
    assert_match "Ascensor B", response.body
  end
end
