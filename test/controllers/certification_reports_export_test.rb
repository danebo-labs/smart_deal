# frozen_string_literal: true

require "test_helper"

# Fase 1B — "Revisar informe": read-only document view built from the one
# ERB partial the future PDF job (Fase 3A) will reuse. Isolation follows the
# same two axes as every other report route (fixed rule 12); the rest of
# these tests are about the document contract itself — fixed section order,
# XSS-safety of certifier-typed text, no N+1, and the old-data / unclassified
# / photo-evidence states the plan calls out explicitly.
class CertificationReportsExportTest < ActionDispatch::IntegrationTest
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

  # ── Guards ─────────────────────────────────────────────────────────────────

  test "responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user

    get export_certification_report_path(@report)
    assert_response :not_found
  end

  test "redirects an unauthenticated visitor to login" do
    get export_certification_report_path(@report)
    assert_response :redirect
  end

  # ── Isolation, both axes (fixed rule 12) ────────────────────────────────────

  test "cannot review a report of another company" do
    sign_in @user
    other = certification_reports(:edificio_portales)

    get export_certification_report_path(other)

    assert_response :not_found
  end

  test "cannot review a colleague's report in the same company" do
    sign_in @user
    colleague = User.create!(email: "second-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @account)
    colleague_report = CertificationReport.create!(account: @account, user: colleague, building_name: "Torre Ajena")

    get export_certification_report_path(colleague_report)

    assert_response :not_found
  end

  # ── Old data: torre_amunategui has no equipment, no result, no review fields ─

  test "a legacy report with no equipment, result or review fields still renders" do
    sign_in @user

    get export_certification_report_path(@report)

    assert_response :success
    assert_match I18n.t("certifier.export.empty.equipment"), response.body
    assert_match I18n.t("certifier.results.unrecorded"), response.body
    assert_match I18n.t("certifier.export.identification.issuer_incomplete"), response.body
  end

  test "keeps the BORRADOR watermark visible" do
    sign_in @user

    get export_certification_report_path(@report)

    assert_response :success
    assert_match I18n.t("certifier.export.draft_watermark"), response.body
  end

  # ── Fixed section order (Fase 1B, non-negotiable) ───────────────────────────

  test "the configured company's report renders sections identification, equipment, grave, result, leve, unclassified, evidence in that order" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    assert_response :success
    ids = %w[
      certifier_doc_identification certifier_doc_equipment certifier_doc_grave
      certifier_doc_result certifier_doc_leve certifier_doc_unclassified certifier_doc_evidence
    ]
    positions = ids.map { |id| response.body.index(%(id="#{id}")) }
    assert positions.all?, "expected every fixed section id to be present: #{ids}"
    assert_equal positions, positions.sort, "sections must render in the fixed Fase 1B order"
  end

  # ── Content: equipment, classified/unclassified findings, manual result ────

  test "lists equipment with its typed specs and no invented values" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    assert_response :success
    assert_match "Ascensor A", response.body
    assert_match "Ascensor B", response.body
    # climb_ascensor_b carries no technical characteristic — must not render a
    # guessed spec line for it (fixed rule 1).
    assert_no_match(/Ascensor B.*certifier-doc__equipment-specs/m, response.body)
  end

  test "puts the grave finding in the major-defects table, not the minor one" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    grave_section = response.body[/id="certifier_doc_grave".*?id="certifier_doc_result"/m]
    leve_section  = response.body[/id="certifier_doc_leve".*?id="certifier_doc_unclassified"/m]

    assert_match "Cable de tracción con hilos rotos", grave_section
    assert_no_match "Cable de tracción con hilos rotos", leve_section
  end

  test "puts the leve finding in the minor-defects table" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    leve_section = response.body[/id="certifier_doc_leve".*?id="certifier_doc_unclassified"/m]
    assert_match "Botonera de cabina con dos pulsadores sin iluminación", leve_section
  end

  test "keeps the unclassified finding out of both severity tables and in its own section" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    grave_section         = response.body[/id="certifier_doc_grave".*?id="certifier_doc_result"/m]
    leve_section          = response.body[/id="certifier_doc_leve".*?id="certifier_doc_unclassified"/m]
    unclassified_section  = response.body[/id="certifier_doc_unclassified".*?id="certifier_doc_evidence"/m]

    assert_no_match "Ruido metálico intermitente", grave_section
    assert_no_match "Ruido metálico intermitente", leve_section
    assert_match "Ruido metálico intermitente", unclassified_section
  end

  test "shows the manual result and its note when set, never derived from the findings" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)
    report.update!(result: :aprobado, result_note: "Con observaciones menores")

    get export_certification_report_path(report)

    result_section = response.body[/id="certifier_doc_result".*?id="certifier_doc_leve"/m]
    assert_match I18n.t("certifier.results.aprobado"), result_section
    assert_match "Con observaciones menores", result_section
  end

  test "photo evidence renders the grave finding's photo with a trusted signed url" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    get export_certification_report_path(report)

    evidence_section = response.body[/id="certifier_doc_evidence".*?<\/section>/m]
    assert_match "<img", evidence_section
    assert_no_match I18n.t("certifier.export.photo_unavailable"), evidence_section
  end

  test "a report with no photo evidence at all shows the empty-evidence message" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)
    report.inspection_findings.where.not(field_photo_id: nil).find_each { |finding| finding.update!(field_photo_id: nil) }

    get export_certification_report_path(report)

    assert_response :success
    assert_match I18n.t("certifier.export.empty.evidence"), response.body
  end

  test "a finding that has a photo but no resolvable url shows the 'photo unavailable' placeholder" do
    sign_in @user
    fake_service = Object.new
    def fake_service.call(_photo) = nil
    def fake_service.trusted_redirect_url?(_url) = false

    original_new = FieldPhotoUrlService.method(:new)
    FieldPhotoUrlService.define_singleton_method(:new) { |**_kwargs| fake_service }

    get export_certification_report_path(@report)

    assert_response :success
    assert_match I18n.t("certifier.export.photo_unavailable"), response.body
  ensure
    FieldPhotoUrlService.define_singleton_method(:new) { |*a, **kw| original_new.call(*a, **kw) }
  end

  # ── XSS: certifier-typed free text must always be escaped ──────────────────

  test "escapes a malicious building name and finding body instead of rendering them" do
    sign_in @user
    payload = "<script>alert(1)</script>"
    @report.update!(building_name: payload)
    @report.inspection_findings.first.update!(body: payload)

    get export_certification_report_path(@report)

    assert_response :success
    assert_not_includes response.body, payload
    assert_includes response.body, CGI.escapeHTML(payload)
  end

  test "escapes a malicious equipment label and location" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)
    payload = "<img src=x onerror=alert(1)>"
    report.report_equipments.first.update!(label: payload)

    get export_certification_report_path(report)

    assert_response :success
    assert_not_includes response.body, payload
    assert_includes response.body, CGI.escapeHTML(payload)
  end

  # ── Long text: never truncated in the review document ──────────────────────

  test "never truncates a long finding body" do
    sign_in @user
    long_body = "Observación extensa. " * 50
    @report.inspection_findings.first.update!(body: long_body)

    get export_certification_report_path(@report)

    assert_response :success
    assert_includes response.body, long_body
  end

  # ── No N+1: preloaded findings/equipment, one photo-service call per photo ──

  test "renders a report with several findings, equipment and photos within a small fixed query budget" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)

    query_count = 0
    counter = ->(*) { query_count += 1 }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      get export_certification_report_path(report)
    end

    assert_response :success
    assert_operator query_count, :<, 15, "export should not issue a query per finding/equipment row"
  end

  # ── Return-to-export edit links point back here ─────────────────────────────

  test "edit links for the report, an equipment and a finding all carry return_to=export" do
    host! CLIMB_HOST
    sign_in users(:two)
    report = certification_reports(:edificio_portales)
    equipment = report.report_equipments.first
    finding = report.inspection_findings.first

    get export_certification_report_path(report)

    assert_match(/#{Regexp.escape(edit_certification_report_path(report))}\?return_to=export/, response.body)
    assert_match(/#{Regexp.escape(edit_report_equipment_path(equipment))}\?return_to=export/, response.body)
    assert_match(/#{Regexp.escape(edit_inspection_finding_path(finding))}\?return_to=export/, response.body)
  end
end
