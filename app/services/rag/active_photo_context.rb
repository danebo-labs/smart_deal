# frozen_string_literal: true

module Rag
  # Read-only projection of the episode's active photo. One indexed lookup.
  # No S3, no image bytes, and no vision call.
  class ActivePhotoContext
    MAX_BYTES = 640
    MAX_LABEL = 60
    MAX_VISIBLE = 4
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

      new(status: "loaded", field_photo_id: row.first, projection: projection)
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
      }.uniq.first(MAX_VISIBLE)
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

    def initialize(status:, field_photo_id:, projection:)
      @status = status
      @field_photo_id = field_photo_id
      @projection = projection
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
      terms.concat(Array(projection["visible_text"]))
      terms
    end

    def generation_block
      return nil unless relevant?

      lines = [ HEADER ]
      lines << "Component: #{projection['component']}" if projection["component"].present?
      lines << "Manufacturer: #{projection['manufacturer']}" if projection["manufacturer"].present?
      lines << "Model: #{projection['model']}" if projection["model"].present?
      if Array(projection["visible_text"]).any?
        lines << "Visible text: #{projection['visible_text'].join(', ')}"
      end
      lines << "Condition: #{projection['condition']}" if projection["condition"].present?
      lines << "Read from the active episode photo. Not stated by the technician."
      lines.join("\n")
    end
  end
end
