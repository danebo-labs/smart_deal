# frozen_string_literal: true

require "test_helper"

module Rag
  class DeterministicIntentTest < ActiveSupport::TestCase
    test "document_overview_query? is true for a blank question with one pin" do
      assert DeterministicIntent.document_overview_query?("", [ "Manual SEGURIDADES 1.1-1" ])
      assert DeterministicIntent.document_overview_query?(nil, [ "Manual SEGURIDADES 1.1-1" ])
      assert DeterministicIntent.document_overview_query?("   ", [ "Manual SEGURIDADES 1.1-1" ])
    end

    test "document_overview_query? is true when the question matches canonical_name regardless of case/accents/trailing punctuation" do
      names = [ "Manual SEGURIDADES 1.1-1" ]

      assert DeterministicIntent.document_overview_query?("manual seguridades 1.1-1", names)
      assert DeterministicIntent.document_overview_query?("MANUAL SEGURIDADES 1.1-1.", names)
      assert DeterministicIntent.document_overview_query?("Manual Séguridádes 1.1-1", names)
      assert DeterministicIntent.document_overview_query?("  Manual SEGURIDADES 1.1-1  ", names)
    end

    test "document_overview_query? is true when the question matches an alias" do
      names = [ "Manual SEGURIDADES 1.1-1", "Seguridades ORONA" ]

      assert DeterministicIntent.document_overview_query?("seguridades orona", names)
    end

    test "document_overview_query? is false for a real question" do
      names = [ "Manual SEGURIDADES 1.1-1" ]

      assert_not DeterministicIntent.document_overview_query?("¿cómo pruebo el cerrojo?", names)
    end

    test "document_overview_query? is false when pinned_names is empty, even with a blank question" do
      assert_not DeterministicIntent.document_overview_query?("", [])
      assert_not DeterministicIntent.document_overview_query?(nil, nil)
    end

    test "document_overview_query? is true for a concatenation of two pinned names" do
      names = [ "Manual A", "Manual B" ]

      assert DeterministicIntent.document_overview_query?("Manual A Manual B", names)
    end

    test "document_overview_query? is true for a pinned name concatenated with its alias" do
      names = [ "Manual A", "Alias A2" ]

      assert DeterministicIntent.document_overview_query?("Manual A Alias A2", names)
    end

    test "document_overview_query? is false for a real question with a pinned name embedded in it" do
      names = [ "Manual A" ]

      assert_not DeterministicIntent.document_overview_query?("cómo instalo el Manual A hoy", names)
    end

    test "document_overview_query? is true for a comma-separated concatenation of pinned names" do
      names = [ "Manual A", "Manual B" ]

      assert DeterministicIntent.document_overview_query?("Manual A, Manual B", names)
    end

    test "document_overview_query? is not broken by a short alias that is a substring of a longer pinned name" do
      names = [ "Manual", "Manual A" ]

      assert DeterministicIntent.document_overview_query?("Manual A", names)
    end

    # "y"/"and" as a bare connector word is not stripped by the current
    # implementation (only punctuation is normalized away) — a technician who
    # types "Manual A y Manual B" still falls through to the RAG path.
    test "document_overview_query? is false for names joined by a bare 'y' connector (unsupported)" do
      names = [ "Manual A", "Manual B" ]

      assert_not DeterministicIntent.document_overview_query?("Manual A y Manual B", names)
    end
  end
end
