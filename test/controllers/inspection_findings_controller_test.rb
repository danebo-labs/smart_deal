# frozen_string_literal: true

require "test_helper"

class InspectionFindingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  class FakeS3
    attr_reader :uploads

    def initialize
      @uploads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      key
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  def photo_upload
    fixture_file_upload("tiny.png", "image/png")
  end

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @user    = users(:one)
    @account = accounts(:legacy)
    @report  = certification_reports(:torre_amunategui)
    @finding = inspection_findings(:pozo_iluminacion)
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end

  def other_user_in_legacy
    User.create!(email: "second-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @account)
  end

  # ── Feature flag guard ─────────────────────────────────────────────────

  test "create responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user

    post certification_report_inspection_findings_path(@report), params: { inspection_finding: { body: "x" } }
    assert_response :not_found
  end

  # ── create: attaching a photo is the SAME submit, no extra screen ─────

  test "creates a finding with only body text" do
    sign_in @user

    assert_difference("@report.inspection_findings.count", 1) do
      post certification_report_inspection_findings_path(@report),
           params: { inspection_finding: { body: "Cable de tracción con desgaste visible", location: "Sala de máquinas" } }
    end

    assert_redirected_to certification_report_path(@report)
    finding = @report.inspection_findings.find_by!(body: "Cable de tracción con desgaste visible")
    assert_equal "Sala de máquinas", finding.location
    assert_nil finding.field_photo_id
  end

  test "creates a finding and attaches its photo in the same request" do
    sign_in @user
    fake = FakeS3.new

    with_fake_s3(fake) do
      post certification_report_inspection_findings_path(@report),
           params: { inspection_finding: { body: "Puerta de foso oxidada", photo: photo_upload } }
    end

    assert_redirected_to certification_report_path(@report)
    finding = @report.inspection_findings.find_by!(body: "Puerta de foso oxidada")
    assert finding.field_photo_id.present?
    assert_equal @account.id, finding.field_photo.account_id
    assert_equal 1, fake.uploads.size
  end

  test "create without a body re-renders the report with a 422 and no record" do
    sign_in @user

    assert_no_difference("InspectionFinding.count") do
      post certification_report_inspection_findings_path(@report), params: { inspection_finding: { body: "" } }
    end

    assert_response :unprocessable_entity
    assert_match @report.building_name, response.body
  end

  test "create responds 404 for another user's report in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")

    post certification_report_inspection_findings_path(colleague_report), params: { inspection_finding: { body: "x" } }
    assert_response :not_found
  end

  test "create responds 404 for another account's report" do
    sign_in @user
    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")

    post certification_report_inspection_findings_path(other_report), params: { inspection_finding: { body: "x" } }
    assert_response :not_found
  end

  # ── edit/update ─────────────────────────────────────────────────────────

  test "edit responds 404 for a finding whose report belongs to another user in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")
    colleague_finding = InspectionFinding.create!(certification_report: colleague_report, body: "Ajeno")

    get edit_inspection_finding_path(colleague_finding)
    assert_response :not_found
  end

  test "edit responds 404 for a finding whose report belongs to another account" do
    sign_in @user
    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")
    other_finding = InspectionFinding.create!(certification_report: other_report, body: "Ajeno")

    get edit_inspection_finding_path(other_finding)
    assert_response :not_found
  end

  test "edit renders the finding form, including a link to its photo when attached" do
    sign_in @user
    finding_with_photo = inspection_findings(:cabina_puerta)

    get edit_inspection_finding_path(finding_with_photo)

    assert_response :success
    assert_match finding_with_photo.body, response.body
    assert_match(/min-h-\[72px\]/, response.body)
  end

  test "updates the finding's text" do
    sign_in @user

    patch inspection_finding_path(@finding), params: { inspection_finding: { body: "Texto corregido" } }

    assert_redirected_to certification_report_path(@report)
    assert_equal "Texto corregido", @finding.reload.body
  end

  test "update responds 404 for another user's finding in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")
    colleague_finding = InspectionFinding.create!(certification_report: colleague_report, body: "Ajeno")

    patch inspection_finding_path(colleague_finding), params: { inspection_finding: { body: "hackeado" } }

    assert_response :not_found
    assert_equal "Ajeno", colleague_finding.reload.body
  end

  # ── destroy ─────────────────────────────────────────────────────────────

  test "destroys the finding and redirects to its report" do
    sign_in @user

    assert_difference("InspectionFinding.count", -1) do
      delete inspection_finding_path(@finding)
    end

    assert_redirected_to certification_report_path(@report)
  end

  test "destroy responds 404 for another user's finding in the same account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")
    colleague_finding = InspectionFinding.create!(certification_report: colleague_report, body: "Ajeno")

    delete inspection_finding_path(colleague_finding)

    assert_response :not_found
    assert InspectionFinding.exists?(colleague_finding.id)
  end

  # ── Fase 1A: the certifier's manual classification ─────────────────────────

  # Fixed rule 4: dictation asks for nothing. The classification fields live in
  # the editor, so creating a finding must still take only its text.
  test "creating a finding asks for nothing but its text" do
    sign_in @user
    @report.report_equipments.create!(label: "Ascensor A")

    post certification_report_inspection_findings_path(@report), params: { inspection_finding: { body: "Dictado sin clasificar" } }

    finding = @report.inspection_findings.find_by!(body: "Dictado sin clasificar")
    assert_nil finding.report_equipment_id
    assert_nil finding.severity
    assert_nil finding.inspection_item
  end

  test "the editor assigns an equipment, an item and a severity" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    patch inspection_finding_path(@finding), params: {
      inspection_finding: {
        body: @finding.body, report_equipment_id: equipment.id,
        inspection_item: "6", severity: "grave", nch2840_box: "6.3", norm_point: "5.4.2"
      }
    }

    assert_redirected_to certification_report_path(@report)
    @finding.reload
    assert_equal equipment.id, @finding.report_equipment_id
    assert_equal 6, @finding.inspection_item
    assert @finding.severity_grave?
    assert_equal "6.3", @finding.nch2840_box
  end

  test "an empty selection clears the classification instead of storing a blank" do
    sign_in @user
    equipment = @report.report_equipments.create!(label: "Ascensor A")
    @finding.update!(report_equipment: equipment, severity: "leve", inspection_item: 2)

    patch inspection_finding_path(@finding), params: {
      inspection_finding: { body: @finding.body, report_equipment_id: "", severity: "", inspection_item: "" }
    }

    @finding.reload
    assert_nil @finding.report_equipment_id
    assert_nil @finding.severity
    assert_nil @finding.inspection_item
  end

  test "a blank order field leaves the position untouched" do
    sign_in @user
    @finding.update!(position: 7)

    patch inspection_finding_path(@finding), params: { inspection_finding: { body: @finding.body, position: "" } }

    assert_equal 7, @finding.reload.position
  end

  # An equipment id from another report must not be attachable even though both
  # reports belong to the same user and the same company.
  test "rejects an equipment of another report" do
    sign_in @user
    other_report = CertificationReport.create!(account: @account, user: @user, building_name: "Otro edificio")
    foreign = other_report.report_equipments.create!(label: "Ascensor X")

    patch inspection_finding_path(@finding), params: { inspection_finding: { body: @finding.body, report_equipment_id: foreign.id } }

    assert_response :unprocessable_entity
    assert_nil @finding.reload.report_equipment_id
  end

  test "rejects an equipment of another company" do
    sign_in @user

    patch inspection_finding_path(@finding), params: {
      inspection_finding: { body: @finding.body, report_equipment_id: report_equipments(:climb_ascensor_a).id }
    }

    assert_response :unprocessable_entity
    assert_nil @finding.reload.report_equipment_id
  end

  test "an invalid severity responds 422 instead of raising" do
    sign_in @user

    patch inspection_finding_path(@finding), params: { inspection_finding: { body: @finding.body, severity: "gravisimo" } }

    assert_response :unprocessable_entity
    assert_nil @finding.reload.severity
  end

  test "an invalid CENTRAVE item responds 422" do
    sign_in @user

    patch inspection_finding_path(@finding), params: { inspection_finding: { body: @finding.body, inspection_item: "99" } }

    assert_response :unprocessable_entity
    assert_nil @finding.reload.inspection_item
  end

  # An unclassified finding must read as pending, never as "sin defectos".
  test "the report shows an unclassified finding as pending, not as compliant" do
    sign_in @user

    get certification_report_path(@report)

    assert_response :success
    assert_match I18n.t("certifier.finding.unclassified_severity"), response.body
    assert_match I18n.t("certifier.equipment.unassigned"), response.body
  end

  test "the editor opens for a legacy finding with no classification at all" do
    sign_in @user

    get edit_inspection_finding_path(@finding)

    assert_response :success
    assert_match I18n.t("certifier.finding.no_equipments_hint"), response.body
  end

  # ── Fase 1B: "return_to=export" — direct return to the review page ─────────

  test "editing from the review page returns to it, anchored to the finding, on save" do
    sign_in @user

    patch inspection_finding_path(@finding, return_to: "export"), params: { inspection_finding: { body: @finding.body } }

    assert_redirected_to export_certification_report_path(@report, anchor: ActionView::RecordIdentifier.dom_id(@finding))
  end

  test "an arbitrary return_to value is ignored, never treated as a redirect target" do
    sign_in @user

    patch inspection_finding_path(@finding, return_to: "http://evil.example.com"), params: { inspection_finding: { body: @finding.body } }

    assert_redirected_to certification_report_path(@report)
  end

  test "the edit form carries return_to=export through to its save url" do
    sign_in @user

    get edit_inspection_finding_path(@finding, return_to: "export")

    assert_response :success
    assert_match(/action="#{Regexp.escape(inspection_finding_path(@finding))}\?return_to=export"/, response.body)
  end
end
