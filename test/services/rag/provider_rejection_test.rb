# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_journey_evidence"

# Retrieve returned nothing. The absence notice stays, and it is not the
# generation-failure notice used when a retrieved passage was in hand.
class Rag::ProviderRejectionTest < ActiveSupport::TestCase
  include CompanionJourneyEvidence

  setup do
    @require = ENV["GUION2_DIRECT_REQUIRE"]
    ENV["GUION2_DIRECT_REQUIRE"] = "1"
    unless defined?(Guion2Direct) && Guion2Direct.respond_to?(:turn_status)
      load Rails.root.join("script/field_companion/run_guion2.rb")
    end
  end

  teardown do
    @require.nil? ? ENV.delete("GUION2_DIRECT_REQUIRE") : ENV["GUION2_DIRECT_REQUIRE"] = @require
  end

  test "an empty retrieve publishes the absence notice and the runner can continue" do
    passage = captured_section_58
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "test-kb")
    retrieve_calls = 0
    prompts = []
    orientation = "Orientación de Danebo: el síntoma queda abierto hasta contar con un manual aplicable."
    service.define_singleton_method(:retrieve_chunks) do |*, **|
      retrieve_calls += 1
      { chunks: [], retrieval_trace: {} }
    end
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params| flunk "empty retrieval must not retrieve_and_generate" }
    generator = Object.new
    generator.define_singleton_method(:query) do |prompt, **|
      prompts << prompt
      orientation
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    context = <<~TEXT
      ## Active Field Problem
      Goal: la puerta no cierra
      Manufacturer: Elemont (catalog)
    TEXT

    result = service.query(
      "la puerta no cierra",
      equipment_identity: nil,
      session_context: context,
      output_channel: :web,
      response_locale: :es
    )

    assert_equal 1, retrieve_calls
    assert_equal 1, prompts.size
    assert_includes result[:answer], I18n.t("rag.empty_search_notice", locale: :es)
    assert_includes result[:answer], orientation
    assert_not_includes result[:answer], I18n.t("rag.generation_failed", locale: :es)
    assert_not_includes result[:answer], I18n.t("rag.generation_failed", locale: :en)
    assert_not_includes result[:answer], passage
    assert_not_includes citation_text(result), "se abrirán lentamente"
    assert_nil result[:provider_rejection]

    wrapped = RagQueryConcern::RagResult.new(success?: true, answer: result[:answer])
    assert_equal "returned", Guion2Direct.turn_status(wrapped, nil, nil)
  end

  test "an access rejection is the only status that stops the next turn" do
    denied = RagQueryConcern::RagResult.new(
      success?: true,
      answer: I18n.t("rag.generation_failed", locale: :es),
      provider_rejection: "access_denied",
      provider_error_message: captured_provider_rejection
    )
    absent = RagQueryConcern::RagResult.new(
      success?: true,
      answer: I18n.t("rag.empty_search_notice", locale: :es)
    )
    validation = RagQueryConcern::RagResult.new(
      success?: true,
      answer: I18n.t("rag.generation_failed", locale: :es),
      provider_error_message: "ValidationException"
    )

    assert_equal "provider_rejected", Guion2Direct.turn_status(denied, nil, nil)
    assert_equal "returned", Guion2Direct.turn_status(absent, nil, nil)
    assert_equal "returned", Guion2Direct.turn_status(validation, nil, nil)

    calls = 0
    [ denied, absent ].each do |result|
      calls += 1
      break if Guion2Direct.turn_status(result, nil, nil) != "returned"
    end
    assert_equal 1, calls
  end

  private

  def citation_text(result)
    Array(result[:retrieved_citations]).map { |item|
      next item.to_s unless item.respond_to?(:[])

      item[:content] || item["content"]
    }.join("\n")
  end
end
