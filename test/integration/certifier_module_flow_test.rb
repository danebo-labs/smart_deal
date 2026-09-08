# frozen_string_literal: true

require "test_helper"

# Fase 2 closing criterion (docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md):
# a user creates a report, adds 3 findings (one with a photo), signs out,
# comes back and finds it intact — the non-voice version of the persistence
# requirement in plan de septiembre section 10, points 1–2.
class CertifierModuleFlowTest < ActionDispatch::IntegrationTest
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

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @user = users(:one)
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end

  test "create report, add 3 findings with a photo, sign out, sign back in: everything is intact" do
    sign_in @user

    post certification_reports_path, params: { certification_report: { building_name: "Torre Persistencia" } }
    report = CertificationReport.find_by!(building_name: "Torre Persistencia")
    assert_equal @user.id, report.user_id

    post certification_report_inspection_findings_path(report),
         params: { inspection_finding: { body: "Puerta de cabina roza", location: "Cabina" } }
    post certification_report_inspection_findings_path(report),
         params: { inspection_finding: { body: "Iluminación de pozo apagada", location: "Pozo" } }

    fake = FakeS3.new
    with_fake_s3(fake) do
      post certification_report_inspection_findings_path(report),
           params: { inspection_finding: { body: "Cable de tracción con desgaste", photo: fixture_file_upload("tiny.png", "image/png") } }
    end

    assert_equal 3, report.inspection_findings.count

    sign_out @user
    get certification_report_path(report)
    assert_response :redirect # Devise sends signed-out visitors to login

    sign_in @user

    get certification_report_path(report)
    assert_response :success
    assert_match "Torre Persistencia", response.body
    assert_match "Puerta de cabina roza", response.body
    assert_match "Iluminación de pozo apagada", response.body
    assert_match "Cable de tracción con desgaste", response.body

    photo_backed = report.inspection_findings.with_photo.first
    assert photo_backed.present?
    assert_equal @user.account_id, photo_backed.field_photo.account_id

    get certification_reports_path
    assert_response :success
    assert_match "Torre Persistencia", response.body
  end
end
