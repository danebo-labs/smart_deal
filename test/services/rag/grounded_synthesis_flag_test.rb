# frozen_string_literal: true

require "test_helper"

class Rag::GroundedSynthesisFlagTest < ActiveSupport::TestCase
  test "enabled? is off by default and on only by exact true" do
    with_enabled(nil) { assert_not Rag::GroundedSynthesisFlag.enabled? }
    with_enabled("true") { assert Rag::GroundedSynthesisFlag.enabled? }
    with_enabled("false") { assert_not Rag::GroundedSynthesisFlag.enabled? }
    with_enabled("TRUE") { assert_not Rag::GroundedSynthesisFlag.enabled? }
  end

  test "enabled_for? is true for any account and nil when the list is empty or absent" do
    account = Struct.new(:id).new(3)

    with_enabled("true") do
      with_account_ids(nil) do
        assert Rag::GroundedSynthesisFlag.enabled_for?(account)
        assert Rag::GroundedSynthesisFlag.enabled_for?(nil)
      end

      with_account_ids("") do
        assert Rag::GroundedSynthesisFlag.enabled_for?(account)
        assert Rag::GroundedSynthesisFlag.enabled_for?(nil)
      end

      with_account_ids("  ") do
        assert Rag::GroundedSynthesisFlag.enabled_for?(account)
        assert Rag::GroundedSynthesisFlag.enabled_for?(nil)
      end
    end
  end

  test "enabled_for? is false for every account when the flag is off" do
    account = Struct.new(:id).new(3)

    with_enabled("false") do
      with_account_ids(nil) { assert_not Rag::GroundedSynthesisFlag.enabled_for?(account) }
      with_account_ids("3") { assert_not Rag::GroundedSynthesisFlag.enabled_for?(account) }
    end
  end

  test "a non-empty account list restricts to those ids and tolerates spaces" do
    inside = Struct.new(:id).new(3)
    outside = Struct.new(:id).new(9)

    with_enabled("true") do
      with_account_ids("3, 5") do
        assert Rag::GroundedSynthesisFlag.enabled_for?(inside)
        assert Rag::GroundedSynthesisFlag.enabled_for?(5)
        assert_not Rag::GroundedSynthesisFlag.enabled_for?(outside)
        assert_not Rag::GroundedSynthesisFlag.enabled_for?(nil)
      end

      with_account_ids(" 3 ") do
        assert Rag::GroundedSynthesisFlag.enabled_for?(inside)
        assert_not Rag::GroundedSynthesisFlag.enabled_for?(outside)
      end
    end
  end

  private

  def with_enabled(value)
    original = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ENABLED", nil)
    if value.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ENABLED")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] = original
    end
  end

  def with_account_ids(value)
    original = ENV.fetch("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS", nil)
    if value.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS")
    else
      ENV["RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS"] = original
    end
  end
end
