# frozen_string_literal: true

module Rag
  # Explicit identity a retrieved chunk already carries, and the heading text
  # that does not.
  #
  # A signal is one metadata field, with its own slot and that field name as
  # provenance:
  #
  #   board_model       → :board      the plate designator
  #   controller_model  → :controller the controller designator
  #   section_identity  → :section    family or section grouping
  #
  # The slots are not interchangeable. Manufacturer is not a slot. A code in
  # the body is not a slot. A "## " heading is a presentation label: its
  # position is not the start of a page, and leftover tokens are not a plate.
  # Absent fields leave that slot undetermined. Nil is not compatibility and
  # not proof that no other plate exists.
  #
  # Compilation pages that name a board only in the heading do not demonstrate
  # a plate. Mention matching may still use the heading text as a hint. That
  # hint is not sufficient for a plate clarification.
  module PlateIdentity
    Signal = Data.define(:slot, :value, :provenance)

    FIELDS = {
      "board_model" => :board,
      "controller_model" => :controller,
      "section_identity" => :section
    }.freeze

    module_function

    def signals(chunk)
      metadata = metadata_of(chunk)
      FIELDS.filter_map do |field, slot|
        value = metadata[field].to_s.strip.presence
        Signal.new(slot: slot, value: value, provenance: field) if value
      end
    end

    def board_signal(chunk)
      signals(chunk).find { |signal| signal.slot == :board }
    end

    def controller_signal(chunk)
      signals(chunk).find { |signal| signal.slot == :controller }
    end

    def section_signal(chunk)
      signals(chunk).find { |signal| signal.slot == :section }
    end

    # Demonstrated plate, or nil when the board slot is absent.
    def designator(chunk)
      board_signal(chunk)&.value
    end

    # Same value as the board slot. A heading or a section does not fill it.
    def board_key(chunk)
      designator(chunk)
    end

    # Heading text for display and for mention matching. Not a demonstrated plate.
    def presentation_label(chunk)
      Rag::BoardHeading.label(chunk.is_a?(String) ? chunk : chunk_content(chunk))
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
