# frozen_string_literal: true

require "test_helper"

class ReportEquipmentTest < ActiveSupport::TestCase
  setup do
    @report = certification_reports(:torre_amunategui)
  end

  test "requires a visible label" do
    equipment = @report.report_equipments.new(label: "")

    assert_not equipment.valid?
    assert_includes equipment.errors.attribute_names, :label
  end

  test "inherits the account from its report" do
    equipment = @report.report_equipments.create!(label: "Ascensor A")

    assert_equal @report.account_id, equipment.account_id
  end

  test "rejects an account that does not match its report" do
    equipment = ReportEquipment.new(certification_report: @report, account: accounts(:climb), label: "Ascensor A")

    assert_not equipment.valid?
    assert_includes equipment.errors.attribute_names, :account_id
  end

  test "saves with every technical characteristic blank" do
    equipment = @report.report_equipments.new(label: "Ascensor sin datos")

    assert equipment.save
    assert_nil equipment.machine_room
    assert_nil equipment.speed_mps
    assert_nil equipment.last_maintenance_date
  end

  test "rejects a machine room or drive type outside the recorded options" do
    equipment = @report.report_equipments.new(label: "A", machine_room: "quizas", drive_type: "neumatico")

    assert_not equipment.valid?
    assert_includes equipment.errors.attribute_names, :machine_room
    assert_includes equipment.errors.attribute_names, :drive_type
  end

  # Deleting an equipment must never take confirmed findings with it.
  test "refuses to be destroyed while a finding still points at it" do
    equipment = report_equipments(:climb_ascensor_a)

    assert_not equipment.destroy
    assert equipment.persisted?
    assert equipment.errors[:base].any?, "the certifier must be told why, not silently fail"
  end

  test "is destroyed once no finding points at it" do
    equipment = report_equipments(:climb_ascensor_b)

    assert equipment.destroy
  end

  test "ordered sorts by position" do
    labels = certification_reports(:edificio_portales).report_equipments.ordered.pluck(:label)

    assert_equal [ "Ascensor A", "Ascensor B" ], labels
  end

  # Destroying a report must still work: its findings go first, then its
  # equipment, so the restrictive foreign key is never hit.
  test "a report with equipment and findings is destroyed cleanly" do
    report = certification_reports(:edificio_portales)

    assert_difference [ "ReportEquipment.count", "InspectionFinding.count" ], -2 do
      assert report.destroy
    end
  end
end
