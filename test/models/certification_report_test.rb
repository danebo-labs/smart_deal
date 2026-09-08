# frozen_string_literal: true

require "test_helper"

class CertificationReportTest < ActiveSupport::TestCase
  def report_attrs(overrides = {})
    {
      account: accounts(:legacy),
      user: users(:one),
      building_name: "Edificio Catedral 1401"
    }.merge(overrides)
  end

  def other_user_in_legacy
    User.create!(
      email: "second-#{SecureRandom.hex(4)}@example.com",
      password: "password123",
      account: accounts(:legacy)
    )
  end

  test "valid with an account, an owner and an identifiable building name" do
    assert CertificationReport.new(report_attrs).valid?
  end

  test "requires an identifiable building name" do
    report = CertificationReport.new(report_attrs(building_name: nil))
    assert_not report.valid?
    assert report.errors[:building_name].any?
  end

  test "every other building field is optional" do
    report = CertificationReport.new(report_attrs)
    assert_nil report.commune
    assert_nil report.municipal_reception_date
    assert report.valid?
  end

  test "requires an owner" do
    report = CertificationReport.new(report_attrs(user: nil))
    assert_not report.valid?
    assert report.errors[:user].any?
  end

  # The DB-level half of "mis informes is per-user property" (fixed rule 12):
  # no code path, console included, can leave a report unowned.
  test "the database rejects a report without user_id" do
    assert_raises(ActiveRecord::NotNullViolation) do
      CertificationReport.connection.execute(<<~SQL.squish)
        INSERT INTO certification_reports (account_id, status, building_name, created_at, updated_at)
        VALUES (#{accounts(:legacy).id}, 'en_progreso', 'Informe sin dueño', now(), now())
      SQL
    end
  end

  test "starts en_progreso and walks the draft lifecycle" do
    report = CertificationReport.create!(report_attrs)
    assert report.en_progreso?

    report.listo_revision!
    assert report.listo_revision?

    report.enviado!
    assert_equal "enviado", report.reload.status
  end

  # Fixed rule 1: status tracks the draft, never an inspection verdict.
  test "exposes no approved or rejected state" do
    assert_equal %w[en_progreso listo_revision enviado], CertificationReport.statuses.keys
  end

  test "owned_by excludes another user of the same account and other accounts" do
    mine       = CertificationReport.create!(report_attrs)
    colleague  = CertificationReport.create!(report_attrs(user: other_user_in_legacy))
    other_acct = CertificationReport.create!(report_attrs(account: accounts(:climb), user: users(:two)))

    scoped = CertificationReport.owned_by(account_id: accounts(:legacy).id, user_id: users(:one).id)

    assert_includes scoped, mine
    assert_not_includes scoped, colleague
    assert_not_includes scoped, other_acct
  end

  test "findings come back in manual position order" do
    report = certification_reports(:torre_amunategui)
    assert_equal [ 0, 1, 2 ], report.inspection_findings.map(&:position)
  end

  test "destroying a report destroys its findings" do
    report = certification_reports(:torre_amunategui)
    finding_ids = report.inspection_findings.pluck(:id)
    assert_equal 3, finding_ids.size

    report.destroy!

    assert_equal 0, InspectionFinding.where(id: finding_ids).count
  end

  # Guards the association order in Account: the report guard must abort the
  # destroy before the field_photos cascade reaches the evidence FK.
  test "an account holding reports cannot be destroyed and its evidence survives" do
    account = Account.create!(display_name: "Certifier Co", slug: "certifier-#{SecureRandom.hex(4)}")
    photo   = FieldPhoto.create!(
      account: account, sha256: SecureRandom.hex(32),
      s3_key_original: "field_photos/#{account.id}/x/original.jpg",
      content_type: "image/jpeg", byte_size: 10
    )
    report = CertificationReport.create!(report_attrs(account: account))
    InspectionFinding.create!(certification_report: report, body: "Hallazgo con evidencia", field_photo: photo)

    assert_not account.destroy
    assert account.errors[:base].any?
    assert FieldPhoto.exists?(photo.id)
  end
end
