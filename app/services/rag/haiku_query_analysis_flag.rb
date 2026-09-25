# frozen_string_literal: true

module Rag
  # P1 shadow stays observational. P3 conditional owns only switch and correct. always stays inert.
  module HaikuQueryAnalysisFlag
    MODES = %w[off shadow conditional always].freeze
    ENV_KEY = "HAIKU_QUERY_ANALYSIS_MODE"

    module_function

    def mode
      raw = ENV.fetch(ENV_KEY, "off").to_s.strip
      raw = "off" if raw.empty?
      return raw if MODES.include?(raw)

      warn_unknown(raw)
      "off"
    end

    def shadow?
      mode == "shadow"
    end

    def conditional?
      mode == "conditional"
    end

    def reset_unknown_warning!
      @unknown_warned = false
    end

    def warn_unknown(raw)
      return if @unknown_warned

      @unknown_warned = true
      Rails.logger.warn("haiku_query_analysis_flag unknown_mode=#{raw.inspect} treated_as=off")
    end
  end
end
