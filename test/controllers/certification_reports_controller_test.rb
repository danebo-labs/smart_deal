# frozen_string_literal: true

require "test_helper"

class CertificationReportsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

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

  # ── Feature flag guard (section 2.1) ───────────────────────────────────────

  test "index responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user

    get certification_reports_path
    assert_response :not_found
  end

  test "show responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user

    get certification_report_path(@report)
    assert_response :not_found
  end

  test "redirects an unauthenticated visitor to login" do
    get certification_reports_path
    assert_response :redirect
  end

  # ── index: "mis informes" — property by user, not just by account ─────────

  test "index lists only the current user's own reports" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "Torre Ajena")
    other_account_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Edificio Climb")

    get certification_reports_path

    assert_response :success
    assert_match @report.building_name, response.body
    assert_no_match(/Torre Ajena/, response.body)
    assert_no_match(/Edificio Climb/, response.body)
    assert colleague_report.persisted? && other_account_report.persisted?
  end

  test "index issues one query for finding counts regardless of how many reports exist" do
    sign_in @user
    2.times { |n| CertificationReport.create!(account: @account, user: @user, building_name: "Extra #{n}") }

    queries = []
    cb = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /\Aselect/i && payload[:name] != "SCHEMA" }
    ActiveSupport::Notifications.subscribed(cb, "sql.active_record") do
      get certification_reports_path
    end

    finding_queries = queries.select { |q| q.include?("inspection_findings") }
    assert_equal 1, finding_queries.size, "expected includes(:inspection_findings) to issue exactly one query"
  end

  test "index primary action and list rows meet the tap-target minimums (section 2.3)" do
    sign_in @user
    get certification_reports_path

    assert_response :success
    assert_match(/min-h-\[72px\]/, response.body, "the primary action must be at least 72px")
    assert_match(/min-h-\[60px\]/, response.body, "every other control must be at least 60px")
    assert_match(/space-y-4|gap-4/, response.body, "adjacent controls need at least 16px of spacing")
  end

  # ── show: double isolation — cross-account AND cross-user (fixed rule 12) ─

  test "show renders the owner's own report" do
    sign_in @user
    get certification_report_path(@report)
    assert_response :success
    assert_match @report.building_name, response.body
  end

  test "show responds 404 for a report belonging to another account" do
    sign_in @user
    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")

    get certification_report_path(other_report)
    assert_response :not_found
  end

  test "show responds 404 for another user's report in the SAME account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")

    get certification_report_path(colleague_report)
    assert_response :not_found
  end

  test "new renders the report form" do
    sign_in @user
    get new_certification_report_path
    assert_response :success
    assert_match(/min-h-\[72px\]/, response.body)
  end

  # ── create: minimal typing — only building_name is required ───────────────

  test "creates a report with only building_name and owns it to the current user" do
    sign_in @user

    assert_difference("CertificationReport.count", 1) do
      post certification_reports_path, params: { certification_report: { building_name: "Nuevo Edificio" } }
    end

    report = CertificationReport.find_by!(building_name: "Nuevo Edificio")
    assert_equal @user.id, report.user_id
    assert_equal @account.id, report.account_id
    assert_equal "en_progreso", report.status
    assert_redirected_to certification_report_path(report)
  end

  test "create without a building name re-renders with a 422 and no record" do
    sign_in @user

    assert_no_difference("CertificationReport.count") do
      post certification_reports_path, params: { certification_report: { building_name: "" } }
    end

    assert_response :unprocessable_entity
  end

  # ── edit/update ─────────────────────────────────────────────────────────

  test "edit renders the building fields form for the owner" do
    sign_in @user
    get edit_certification_report_path(@report)
    assert_response :success
    assert_match @report.building_name, response.body
  end

  test "edit responds 404 for another user's report in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")

    get edit_certification_report_path(colleague_report)
    assert_response :not_found
  end

  test "update changes building fields and status" do
    sign_in @user

    patch certification_report_path(@report), params: {
      certification_report: { commune: "Providencia", status: "listo_revision" }
    }

    assert_redirected_to certification_report_path(@report)
    @report.reload
    assert_equal "Providencia", @report.commune
    assert_equal "listo_revision", @report.status
  end

  test "update with an invalid status responds 422 instead of raising" do
    sign_in @user

    patch certification_report_path(@report), params: { certification_report: { status: "aprobado" } }

    assert_response :unprocessable_entity
    assert_equal "en_progreso", @report.reload.status
  end

  test "update responds 404 for another account's report" do
    sign_in @user
    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")

    patch certification_report_path(other_report), params: { certification_report: { commune: "X" } }
    assert_response :not_found
  end

  # ── destroy ─────────────────────────────────────────────────────────────

  test "destroy removes the report and its findings" do
    sign_in @user
    finding_ids = @report.inspection_findings.pluck(:id)

    delete certification_report_path(@report)

    assert_redirected_to certification_reports_path
    assert_not CertificationReport.exists?(@report.id)
    assert_equal 0, InspectionFinding.where(id: finding_ids).count
  end

  test "destroy responds 404 for another user's report in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")

    delete certification_report_path(colleague_report)

    assert_response :not_found
    assert CertificationReport.exists?(colleague_report.id)
  end

  test "destroy removes the report's equipment along with its findings" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")
    inspection_findings(:pozo_iluminacion).update!(report_equipment: equipment)

    delete certification_report_path(@report)

    assert_redirected_to certification_reports_path
    assert_not ReportEquipment.exists?(equipment.id)
  end

  # ── Fase 1A: manual review fields ──────────────────────────────────────────

  test "update saves the review fields the certifier typed" do
    sign_in @user

    patch certification_report_path(@report), params: {
      certification_report: {
        inspector_name: "C. Schwartz", report_date: "2026-09-09",
        normative_reference: "NCh 2840:2018", result_note: "Se corrigieron dos observaciones en terreno."
      }
    }

    assert_redirected_to certification_report_path(@report)
    @report.reload
    assert_equal "C. Schwartz", @report.inspector_name
    assert_equal Date.new(2026, 9, 9), @report.report_date
    assert_equal "NCh 2840:2018", @report.normative_reference
    assert_match(/dos observaciones/, @report.result_note)
  end

  # Fixed rule 1: the verdict is only ever what a human chose.
  test "the result starts empty and is never derived from the findings" do
    assert_nil @report.result
    assert_equal 3, @report.inspection_findings.count

    sign_in @user
    patch certification_report_path(@report), params: { certification_report: { commune: "Ñuñoa" } }

    assert_nil @report.reload.result, "saving other fields must not produce a verdict"
  end

  test "update records the result the certifier chose" do
    sign_in @user

    patch certification_report_path(@report), params: { certification_report: { result: "rechazado" } }

    assert_redirected_to certification_report_path(@report)
    assert @report.reload.result_rechazado?
  end

  test "the result can be cleared back to unrecorded" do
    sign_in @user
    @report.update!(result: "aprobado")

    patch certification_report_path(@report), params: { certification_report: { result: "" } }

    assert_nil @report.reload.result
  end

  test "update with an invalid result responds 422 and blames the result" do
    sign_in @user

    patch certification_report_path(@report), params: { certification_report: { result: "quizas" } }

    assert_response :unprocessable_entity
    assert_nil @report.reload.result
  end

  # The status is the draft's lifecycle; the result is the verdict. Neither may
  # be written by touching the other.
  test "status and result stay independent" do
    sign_in @user

    patch certification_report_path(@report), params: { certification_report: { status: "enviado" } }
    assert_nil @report.reload.result

    patch certification_report_path(@report), params: { certification_report: { result: "aprobado" } }
    assert_equal "enviado", @report.reload.status
  end

  # Old data: a report created before Fase 1A has none of these columns filled.
  test "a report with no review fields still opens" do
    sign_in @user

    get certification_report_path(@report)

    assert_response :success
    assert_nil @report.inspector_name
    assert_nil @report.result
  end

  # ── Fase 1B: "return_to=export" — direct return to the review page ─────────

  test "editing building info from the review page returns to it on save" do
    sign_in @user

    patch certification_report_path(@report, return_to: "export"), params: { certification_report: { commune: "Ñuñoa" } }

    assert_redirected_to export_certification_report_path(@report)
  end

  test "an arbitrary return_to value is ignored, never treated as a redirect target" do
    sign_in @user

    patch certification_report_path(@report, return_to: "//evil.example.com"), params: { certification_report: { commune: "Ñuñoa" } }

    assert_redirected_to certification_report_path(@report)
  end

  test "the edit form carries return_to=export through to its save url and back link" do
    sign_in @user

    get edit_certification_report_path(@report, return_to: "export")

    assert_response :success
    assert_match(/action="#{Regexp.escape(certification_report_path(@report))}\?return_to=export"/, response.body)
    assert_match export_certification_report_path(@report), response.body
  end
end
