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

    test "ambiguous_hardware_query? is false for EDEL-K2 (letter directly before the digit)" do
      assert_not DeterministicIntent.ambiguous_hardware_query?(
        "En EDEL-K2, ¿qué indica el LED 31 y qué condiciones lo encienden?"
      )
    end

    test "ambiguous_hardware_query? is true for genuinely ambiguous corpus questions" do
      assert DeterministicIntent.ambiguous_hardware_query?(
        "¿Cómo se conectan los cerrojos en las placas de seguridad?"
      )
      assert DeterministicIntent.ambiguous_hardware_query?(
        "¿Cómo aparecen los cerrojos en las placas?"
      )
    end

    test "ambiguous_hardware_query? is false for other alphanumeric corpus model codes" do
      %w[EM3000 MR08 TPR60 TPR70 CR8PH2 EKM66 DL27].each do |code|
        assert_not DeterministicIntent.ambiguous_hardware_query?("¿Qué LED indica seguridad en #{code}?"),
                   "expected #{code} to be recognized as explicit equipment"
      end
    end

    test "a quick-reply selection never re-enters disambiguation" do
      [ "NE 300 – LB II", "LIMITADOR-CABINA", "ARCA III" ].each do |label|
        assert_not DeterministicIntent.ambiguous_hardware_query?(
          "¿Qué LED indica la serie de obstáculo?\nFabricante y placa: #{label}"
        ), "expected the #{label} selection to break the disambiguation loop"
      end
    end

    test "a quick-reply selection never re-enters disambiguation in English" do
      assert_not DeterministicIntent.ambiguous_hardware_query?(
        "What LED indicates the obstacle series?\nManufacturer and board: NE 300 – LB II"
      )
    end
  end
end
