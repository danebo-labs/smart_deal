# frozen_string_literal: true

# Chained Haiku 5.5 comparison. VERTICAL_LADDER_EXECUTE=1 sends the calls.
# The default loads the class and does not call the model.

require Rails.root.join("test/support/companion_vertical_ladder")

if ENV["VERTICAL_LADDER_REQUIRE"] == "1"
  # Loaded by a test. Nothing runs.
elsif ENV["VERTICAL_LADDER_EXECUTE"] == "1"
  exit Rag::CompanionVerticalLadder.execute_sequence
end
