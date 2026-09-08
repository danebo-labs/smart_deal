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
end
