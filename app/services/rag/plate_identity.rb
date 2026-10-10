# frozen_string_literal: true

module Rag
  # What a retrieved chunk demonstrates about a plate, and what it does not.
  #
  # A "## " heading extracts a section. It demonstrates a plate only when it
  # is the page's opening declaration: the first content line, after the
  # bracket headers the chunk already carries. A later "## " is a section of
  # that page. Manufacturer is not a plate slot. Absent board_model,
  # controller_model, opening declaration, and section_identity leave the
  # plate undetermined: nil is not compatibility and not proof that no other
  # plate exists.
  module PlateIdentity
    module_function

    def designator(chunk)
      metadata = metadata_of(chunk)
      metadata["board_model"].to_s.strip.presence ||
        metadata["controller_model"].to_s.strip.presence
    end

    def board_key(chunk)
      designator(chunk).presence ||
        declared_board_heading(chunk_content(chunk)).presence ||
        metadata_of(chunk)["section_identity"].to_s.strip.presence
    end

    # The board a compilation page names on its first content line.
    # Nil for a section heading that follows other content. A line the route
    # prepends ("THIS JOB'S EQUIPMENT", "REFERENCE ONLY") is not page content.
    def declared_board_heading(content)
      line = opening_content_line(content)
      return if line.blank? || !line.match?(Rag::BoardHeading::HEADING_PREFIX)

      label = Rag::BoardHeading.label(line)
      return if label.blank? || Rag::BoardHeading.board_tokens(label).empty?

      label
    end

    def opening_content_line(content)
      content.to_s.lines.map(&:strip).find { |line| content_line?(line) }
    end

    def content_line?(line)
      return false if line.blank? || line.start_with?("[")

      !line.start_with?("THIS JOB'S EQUIPMENT:") &&
        !line.start_with?(DocumentIdentityScope::OTHER_EQUIPMENT_PREFIX)
    end

    def metadata_of(chunk)
      hash = chunk.to_h
      (hash[:metadata] || hash["metadata"]).to_h.stringify_keys
    end

    def chunk_content(chunk)
      hash = chunk.to_h
      (hash[:content] || hash["content"]).to_s
    end
  end
end
