# frozen_string_literal: true

require "test_helper"

class Rag::CitedConditionRestoreTest < ActiveSupport::TestCase
  PASSAGE = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/companion_revision/thyssen_kpvs.json").read)
    .dig("passages", "9a2cad2e366f0641cc5150205c697d3d63484892b2c4cb9871c674bfd77a31f1")

  test "a removed paraphrase is replaced by the literal conditional sentence" do
    source = { "index" => 1, "content" => PASSAGE, "applicability" => "compatible" }
    removed = [ {
      "sentence" => "La fuente [1] indica, para ruido audible muy elevado, disminuir \"KP-VS\" hasta el mínimo de [3,0].",
      "reason" => "unbacked_citation"
    } ]
    restored = Rag::CitedConditionRestore.call(
      text: "El técnico reporta KP-VS = 2,5.",
      sources: [ source ],
      removed: removed
    )

    assert_includes restored, "El técnico reporta KP-VS = 2,5."
    assert_includes restored, "«En caso de ruido audible muy elevado:"
    assert_includes restored, "[1]"
    assert_not_includes restored, "disminuir"
  end

  test "an uncited comparison does not invent a quote" do
    source = { "index" => 1, "content" => PASSAGE, "applicability" => "compatible" }
    restored = Rag::CitedConditionRestore.call(
      text: "El técnico reporta KP-VS = 2,5.",
      sources: [ source ],
      removed: [ { "sentence" => "Con 2,5 el valor queda por debajo de ese mínimo documentado.", "reason" => "uncited_attribution" } ]
    )

    assert_nil restored
  end
end
