# frozen_string_literal: true

# Chained Haiku 5.5 comparison. VERTICAL_LADDER_EXECUTE=1 sends the calls.
# The default loads the class and does not call the model.

require Rails.root.join("test/support/companion_vertical_ladder")

if ENV["VERTICAL_LADDER_REQUIRE"] == "1"
  # Loaded by a test. Nothing runs.
elsif ENV["VERTICAL_LADDER_EXECUTE"] == "1"
  exit Rag::CompanionVerticalLadder.execute_sequence
elsif ENV["VERTICAL_LADDER_BAND"] == "1"
  exit Rag::CompanionVerticalLadder.execute_band
elsif ENV["VERTICAL_LADDER_HIGH"] == "1"
  exit Rag::CompanionVerticalLadder.execute_high
elsif ENV["VERTICAL_LADDER_CLOSURE"] == "1"
  exit Rag::CompanionVerticalLadder.execute_closure
elsif ENV["VERTICAL_LADDER_ADJUSTMENT"] == "1"
  exit Rag::CompanionVerticalLadder.execute_adjustment
elsif ENV["VERTICAL_LADDER_PARAPHRASE"] == "1"
  exit Rag::CompanionVerticalLadder.execute_paraphrase
elsif ENV["VERTICAL_LADDER_SCOPE"] == "1"
  exit Rag::CompanionVerticalLadder.execute_scope
end
