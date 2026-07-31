# frozen_string_literal: true

require "test_helper"

class Rag::FamilyAmbiguityGuardFlagTest < ActiveSupport::TestCase
  test "is enabled only by the exact true string" do
    with_flag(nil) { assert_not Rag::FamilyAmbiguityGuardFlag.enabled? }
    with_flag("true") { assert Rag::FamilyAmbiguityGuardFlag.enabled? }
    with_flag("TRUE") { assert_not Rag::FamilyAmbiguityGuardFlag.enabled? }
    with_flag("1") { assert_not Rag::FamilyAmbiguityGuardFlag.enabled? }
    with_flag("") { assert_not Rag::FamilyAmbiguityGuardFlag.enabled? }
  end

  private

  def with_flag(value)
    original = ENV.fetch("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED")
    else
      ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_FAMILY_AMBIGUITY_GUARD_ENABLED")
    else
      ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] = original
    end
  end
end
