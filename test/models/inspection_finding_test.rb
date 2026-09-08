# frozen_string_literal: true

require "test_helper"

class InspectionFindingTest < ActiveSupport::TestCase
  def report
    @report ||= certification_reports(:torre_amunategui)
  end

  def finding_attrs(overrides = {})
    { certification_report: report, body: "Amortiguador de foso con fuga de aceite." }.merge(overrides)
  end

  def photo_for(account)
    FieldPhoto.create!(
      account: account, sha256: SecureRandom.hex(32),
      s3_key_original: "field_photos/#{account.id}/#{SecureRandom.hex(4)}/original.jpg",
      content_type: "image/jpeg", byte_size: 2048
    )
  end

  test "valid with a report and a body" do
    assert InspectionFinding.new(finding_attrs).valid?
  end

  test "requires the confirmed text" do
    finding = InspectionFinding.new(finding_attrs(body: nil))
    assert_not finding.valid?
    assert finding.errors[:body].any?
  end

  test "location stays free text and is optional" do
    finding = InspectionFinding.new(finding_attrs(location: nil))
    assert finding.valid?
  end

  test "inherits account_id from its report" do
    finding = InspectionFinding.create!(finding_attrs)
    assert_equal report.account_id, finding.account_id
  end

  test "rejects an account_id that does not match the report" do
    finding = InspectionFinding.new(finding_attrs(account: accounts(:climb)))
    assert_not finding.valid?
    assert finding.errors[:account_id].any?
  end

  test "rejects evidence from another account" do
    finding = InspectionFinding.new(finding_attrs(field_photo: photo_for(accounts(:climb))))
    assert_not finding.valid?
    assert finding.errors[:field_photo].any?
  end

  test "photo evidence is optional" do
    finding = InspectionFinding.create!(finding_attrs)
    assert_nil finding.field_photo_id
  end

  # Fixed rule 1: Danebo offers these fields, it never fills them.
  test "the certifier's columns start empty" do
    finding = InspectionFinding.create!(finding_attrs)
    assert_nil finding.severity
    assert_nil finding.nch2840_box
    assert_nil finding.norm_point
    assert_nil finding.inspection_item
  end

  test "accepts the classification a human assigns" do
    finding = InspectionFinding.create!(finding_attrs)

    finding.update!(severity: :grave, nch2840_box: "6.3", norm_point: "NCh 2840:2018 6.3", inspection_item: 5)

    assert finding.severity_grave?
    assert_equal %w[leve grave], InspectionFinding.severities.keys
  end

  test "position defaults to 0 so a finding is orderable without extra input" do
    assert_equal 0, InspectionFinding.new(finding_attrs).position
  end

  test "with_photo returns only findings carrying evidence" do
    assert_equal [ inspection_findings(:cabina_puerta) ], report.inspection_findings.with_photo.to_a
  end

  # The second layer of the evidence retention policy (fixed rule 10): even a
  # direct DELETE cannot take the bytes' row while a finding points at it.
  test "a referenced photo cannot be deleted" do
    photo = photo_for(report.account)
    InspectionFinding.create!(finding_attrs(field_photo: photo))

    assert_raises(ActiveRecord::InvalidForeignKey) { photo.destroy! }
    assert FieldPhoto.exists?(photo.id)
  end
end
