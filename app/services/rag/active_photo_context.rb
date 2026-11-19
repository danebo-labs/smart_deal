# frozen_string_literal: true

module Rag
  # Read-only projection of the episode's active photo. One indexed lookup.
  # No S3, no image bytes, and no vision call.
  class ActivePhotoContext
    MAX_BYTES = 640
    MAX_LABEL = 60
    MAX_RETRIEVAL_LABELS = 4
    GENERATION_VISIBLE_BYTES = 360
    MAX_VISIBLE_CHARS = 40
    HEADER = "Photo Evidence for the active episode"
    STATUSES = %w[absent loaded unavailable invalid stale].freeze

    attr_reader :status, :field_photo_id, :projection

    def self.resolve(episode:, viewer_account:)
      photo_id = episode.respond_to?(:active_photo) ? episode.active_photo&.dig("field_photo_id") : nil
      return new(status: "absent", field_photo_id: nil, projection: nil) if photo_id.blank?
      return new(status: "unavailable", field_photo_id: photo_id, projection: nil) if viewer_account.nil?

      row = FieldPhoto.where(account_id: viewer_account.id, id: photo_id).pick(:id, :visual_observation)
      return new(status: "unavailable", field_photo_id: photo_id, projection: nil) if row.nil?

      observation = FieldPhotoObservation.sanitize(row.last)
      projection = observation && project(observation)
      if projection.nil?
        return new(status: "invalid", field_photo_id: row.first, projection: nil)
      end

      new(status: "loaded", field_photo_id: row.first, projection: projection,
        generation_codes: observation.fetch("visible_text"))
    end

    # Both builders emit a bounded, blank-line-delimited observation block.
    # Keep it independent of the history budget on the generation path.
    def self.generation_evidence(context)
      context.to_s.split(/\n\n+/).find do |block|
        block.start_with?("#{HEADER}\n", "## Photo Evidence (this turn)\n")
      end
    end

    def self.project(observation)
      payload = {
        "source" => "photo",
        "relevance_to_goal" => observation["relevance_to_goal"]
      }
      component = label(observation["canonical_component"])
      manufacturer = label(observation["manufacturer"])
      model = label(observation["model"])
      payload["component"] = component if component
      payload["manufacturer"] = manufacturer if manufacturer
      payload["model"] = model if model
      visible = visible_text(observation["visible_text"])
      payload["visible_text"] = visible if visible.any?
      if observation["condition"].present? && observation["condition"] != "UNKNOWN"
        payload["condition"] = observation["condition"]
      end
      if observation["subsystem"].present? && observation["subsystem"] != "UNKNOWN"
        payload["subsystem"] = observation["subsystem"]
      end
      if observation["target_visible"] == true || observation["target_visible"] == false
        payload["target_visible"] = observation["target_visible"]
      end
      fit(payload)
    end

    def self.label(value)
      text = value.to_s.squish
      return nil if text.blank? || text.casecmp?("unknown")

      text.first(MAX_LABEL)
    end

    def self.visible_text(values)
      Array(values).filter_map { |item|
        text = item.to_s.squish
        next if text.blank? || text.casecmp?("unknown")

        text.first(MAX_VISIBLE_CHARS)
      }.uniq
    end

    def self.fit(payload)
      droppable = %w[target_visible subsystem condition]
      while JSON.generate(payload).bytesize > MAX_BYTES
        key = droppable.shift
        if key
          payload.delete(key)
        elsif payload["visible_text"].is_a?(Array) && payload["visible_text"].any?
          payload["visible_text"].pop
          payload.delete("visible_text") if payload["visible_text"].empty?
        elsif payload.key?("component")
          payload.delete("component")
        elsif payload.key?("manufacturer")
          payload.delete("manufacturer")
        elsif payload.key?("model")
          payload.delete("model")
        else
          return nil
        end
      end
      payload
    end

    private_class_method :project, :label, :visible_text, :fit

    def initialize(status:, field_photo_id:, projection:, generation_codes: nil)
      @status = status
      @field_photo_id = field_photo_id
      @projection = projection
      @generation_codes = generation_codes
    end

    def loaded?
      status == "loaded" && projection.is_a?(Hash)
    end

    def relevant?
      loaded? && projection["relevance_to_goal"] == "relevant"
    end

    def matches?(photo_id)
      loaded? && photo_id.present? && field_photo_id.to_i == photo_id.to_i
    end

    def to_prompt
      return nil unless loaded?

      projection
    end

    def query_terms
      return [] unless relevant?

      terms = %w[component manufacturer model].filter_map { |key| projection[key].presence }
      terms.concat(Array(projection["visible_text"]).first(MAX_RETRIEVAL_LABELS))
      terms
    end

    def self.generation_labels(values)
      labels = Array(values).reject { |text| text.casecmp?("unknown") }
      labels.pop while labels.join(", ").bytesize > GENERATION_VISIBLE_BYTES
      labels
    end

    # The labels the generator receives as read from the photo. Empty when the
    # reading is not shown to generation.
    def observed_labels
      return [] unless presented?

      self.class.generation_labels(@generation_codes || projection["visible_text"])
    end

    def generation_block(include_unconfirmed: false)
      return nil unless presented? || (include_unconfirmed && loaded?)

      lines = [ HEADER ]
      lines << "Component: #{projection['component']}" if projection["component"].present?
      show_identity = relevant? || (include_unconfirmed && projection["relevance_to_goal"] != "uncertain")
      if show_identity
        lines << "Manufacturer: #{projection['manufacturer']}" if projection["manufacturer"].present?
        lines << "Model: #{projection['model']}" if projection["model"].present?
      end
      codes = presented? ? observed_labels : self.class.generation_labels(projection["visible_text"])
      lines << "Visible text: #{codes.join(', ')}" if codes.any?
      if visible_despite_uncertainty? && projection["target_visible"] == true
        lines << "Vision saw the target but was unsure how it relates to this fault. Use labels as observations only."
      end
      if projection["target_visible"] == false
        lines << "The diagnostic target is not visible in this photo. Use the legible labels as observations only."
      end
      lines << "Condition: #{projection['condition']}" if show_identity && projection["condition"].present?
      lines << "Read from the active episode photo. Not stated by the technician."
      lines << "Relevance to the current fault is unconfirmed. Use these details only for visual follow-up." unless relevant?
      lines.join("\n")
    end

    private

    def presented?
      relevant? || visible_despite_uncertainty?
    end

    def visible_despite_uncertainty?
      loaded? && projection["relevance_to_goal"] == "uncertain" &&
        (projection["target_visible"] == true || observed_context?)
    end

    def observed_context?
      projection["component"].present? && projection["visible_text"].present?
    end
  end
end
