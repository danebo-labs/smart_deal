# frozen_string_literal: true

# Resolves adaptive retrieval parameters from session pin signals.
#
# After cost_v2 ingestion, two distinct chunk classes exist:
#   - field_photo_v1  : ~50 tok/chunk  (source="image_upload")
#   - manual_batch_v1 / web_v1 : ~3000 tok/chunk (source="document")
#
# number_of_results is tuned so the token budget passed to Haiku stays roughly
# constant regardless of pin type, reducing unnecessary input cost for document
# sessions while preserving recall for photo sessions.
#
# | Pin signal          | number_of_results | rationale                          |
# |---------------------|-------------------|------------------------------------|
# | photos only         | 10                | small chunks; 10 ≈ 3 manual tokens |
# | documents only      | 7                 | preserve manual recall             |
# | mixed photo+doc     | 7                 | balanced budget                    |
# | no pin (open query) | 8                 | slight savings vs legacy default   |
class RagRetrievalProfile
  def initialize(entity_sources: [])
    @entity_sources = Array(entity_sources).compact
  end

  def number_of_results
    return 8 if @entity_sources.empty?

    photo_count = @entity_sources.count { |s| s == "image_upload" }
    doc_count   = @entity_sources.count { |s| s == "document" }

    if photo_count > 0 && doc_count == 0
      10
    elsif doc_count > 0 && photo_count == 0
      7
    else
      7
    end
  end
end
