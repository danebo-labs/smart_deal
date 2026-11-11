# frozen_string_literal: true

module CompanionJourneyEvidence
  private

  def captured_provider_rejection
    "anthropic.claude-haiku-5-5 is not available for this account."
  end

  def journey_capture(script, turn)
    path = Rails.root.join("test/fixtures/files/field_companion/haiku55_journeys", script, "turn-#{turn}.json")
    JSON.parse(path.read)
  end

  def journey_source(script, turn, filename)
    rows = journey_capture(script, turn).fetch("rows")
    rows.find { |row| row.fetch("uri").end_with?("/#{filename}") } ||
      flunk("#{script} T#{turn} no conserva #{filename}")
  end

  def captured_section_58
    source = journey_source("guion2", 1, "chunk_p8_1.txt")
    passage = source.fetch("content").lines.find do |line|
      line.include?("se abrirán lentamente en la primera operación después de un fallo de alimentación")
    end
    assert passage, "la captura de G2 T1 no conserva el §5.8"
    passage.strip
  end
end
