# frozen_string_literal: true

require "test_helper"

require Rails.root.join("test/support/companion_vertical_ladder")

class Rag::CompanionVerticalLadderTest < ActiveSupport::TestCase
  setup do
    @require = ENV["VERTICAL_LADDER_REQUIRE"]
    ENV["VERTICAL_LADDER_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_vertical_ladder.rb")
  end

  teardown do
    @require.nil? ? ENV.delete("VERTICAL_LADDER_REQUIRE") : ENV["VERTICAL_LADDER_REQUIRE"] = @require
  end

  test "guion 2 chains the new answer and keeps the canonical sources" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    first = ladder.assemble("guion2", 1, [])
    canonical = JSON.parse(Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare/turn-1/request.json").read)
    assert_equal canonical["messages"].last["content"][0]["text"], first["messages"].last["text"]
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, Digest::SHA256.hexdigest(Rag::CompanionDirectAnswer::SYSTEM_PROMPT)

    published = "La cita queda en [1]. Sin pasos."
    second = ladder.assemble("guion2", 2, [ { question: Rag::CompanionVerticalLadder::GUION2_QUESTIONS[0], published: published } ])
    assert_equal %w[user assistant user], second["messages"].pluck("role")
    assert_equal "La cita queda en . Sin pasos.", second["messages"][1]["text"]
    later = JSON.parse(Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare/turn-2/request.json").read)
    assert_equal later["messages"].last["content"][0]["text"], second["messages"].last["text"]
    assert_equal first["fuentes_sha256"], Digest::SHA256.hexdigest(first["messages"].last["text"].split("Fuentes de este turno:\n", 2)[1])
  end

  test "guion 1 uses the accepted capture and does not call the network" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    built = ladder.assemble("guion1", 1, [])
    assert_equal Rag::CompanionVerticalLadder::GUION1_QUESTIONS[0], built["question"]
    assert_includes built["messages"].last["text"], "Fuentes de este turno:"
    assert_equal "simulated", built["stages"]["retrieval"]
    assert_operator built["sources"].size, :>=, 1
    assert_not_includes built["messages"].last["text"], "temperature"
  end

  test "a persistent slow opening that orders autoajuste fails guion 2" do
    ladder = Rag::CompanionVerticalLadder.new(output_root: Dir.mktmpdir, budget: BigDecimal("1"))
    bad = "Si la apertura lenta persiste, realiza el autoajuste."
    good = "#{Rag::CompanionDirectCaptureReplay::SLOW} Si sigue lenta: Esto no está en la documentación cargada en este turno."
    assert_includes ladder.send(:judge_guion2, 1, bad), "t1:autoajuste_if_still_slow"
    assert_empty ladder.send(:judge_guion2, 1, good)
  end
end
