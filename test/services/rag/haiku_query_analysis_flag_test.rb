# frozen_string_literal: true

require "test_helper"

class Rag::HaikuQueryAnalysisFlagTest < ActiveSupport::TestCase
  F = Rag::HaikuQueryAnalysisFlag

  setup { F.reset_unknown_warning! }

  test "an absent or blank flag is owner and explicit off stays off" do
    with_mode(nil) do
      assert_equal "owner", F.mode
      assert F.owner?
    end
    with_mode("") do
      assert_equal "owner", F.mode
    end
    with_mode("off") do
      assert_equal "off", F.mode
      assert_not F.owner?
    end
  end

  test "an unknown flag is off" do
    with_mode("garbage") do
      assert_equal "off", F.mode
      assert_not F.shadow?
    end
  end

  test "conditional is the ownership mode and always stays inert" do
    with_mode("conditional") do
      assert_equal "conditional", F.mode
      assert F.conditional?
      assert_not F.shadow?
    end
    with_mode("always") do
      assert_equal "always", F.mode
      assert_not F.conditional?
      assert_not F.shadow?
    end
    with_mode("owner") do
      assert F.owner?
      assert_not F.conditional?
      assert_not F.shadow?
    end
  end

  test "shadow is the only mode that calls" do
    with_mode("shadow") { assert F.shadow? }
    with_mode("off") { assert_not F.shadow? }
  end

  private

  def with_mode(value)
    previous = ENV[F::ENV_KEY]
    value.nil? ? ENV.delete(F::ENV_KEY) : ENV[F::ENV_KEY] = value
    F.reset_unknown_warning!
    yield
  ensure
    previous.nil? ? ENV.delete(F::ENV_KEY) : ENV[F::ENV_KEY] = previous
  end
end
