# frozen_string_literal: true

require "test_helper"

class BedrockCompanionRetrieveCountTest < ActiveSupport::TestCase
  FOLLOWUP = "Me equivoqué: la referencia que estoy revisando es Chapa nivel 3. ¿Cómo aparece ese recorrido?"
  CASE_TEXT = "#{FOLLOWUP}\nEstoy con un montacargas Elemont MH que no responde a las llamadas. No veo un código de falla y todavía no he hecho mediciones."
  SOURCES = [ "document" ].freeze

  test "a pinned document follow-up without a fault uses sixteen candidates" do
    count = BedrockRagService.companion_profile_count(FOLLOWUP, SOURCES)

    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, count
    assert_equal RagRetrievalProfile::COMPANION_PINNED_CANDIDATES,
      BedrockRagService.companion_retrieve_count(count, companion_focus: true)
  end

  test "the same follow-up keeps the safety budget when the retrieved case still names the fault" do
    count = BedrockRagService.companion_profile_count(CASE_TEXT, SOURCES)

    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS, count
    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS,
      BedrockRagService.companion_retrieve_count(count, companion_focus: true)
  end

  test "a safety count is not widened when the turn is not a companion document focus" do
    count = BedrockRagService.companion_profile_count(CASE_TEXT, SOURCES)

    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS,
      BedrockRagService.companion_retrieve_count(count, companion_focus: false)
  end
end
