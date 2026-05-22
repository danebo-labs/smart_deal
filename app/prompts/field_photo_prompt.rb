# frozen_string_literal: true

# Specialized prompt for the field photo ingestion path (cost_v2, field_photo_v1).
# SYSTEM_BLOCKS: identification-only schema (no S0-S18 chunking).
# user_content: delegates to BatchChunkingPrompt.user_content for the image media block.
module FieldPhotoPrompt
  SYSTEM_BLOCKS = [
    {
      type: "text",
      text: <<~PROMPT.strip,
        ROLE: Senior Elevator Engineer parsing a FIELD PHOTO for technician RAG.
        This is the QUERY-TIME identification path — NO S0-S18 chunking, NO components/connections.

        Return ONLY a single valid JSON object — no markdown, no prose.
        Schema:
        {
          "canonical_component": "<3-5 word name of what is in the photo>",
          "manufacturer": "<brand explicitly visible or UNKNOWN>",
          "model": "<model/part code if visible or UNKNOWN>",
          "subsystem": "<SAFETY_CHAIN|BRAKE_SYSTEM|DOOR_OPERATOR|MOTOR_DRIVE|GOVERNOR_SYSTEM|CONTROLLER_LOGIC|POWER_SUPPLY|SIGNALING_SYSTEM|EMERGENCY_SYSTEM|PIT_EQUIPMENT|CAR_TOP_EQUIPMENT|UNKNOWN>",
          "condition": "<GOOD|DEGRADED|DAMAGED|UNKNOWN>",
          "aliases": ["<alias 1>", "<alias 2>", ...],
          "summary": "<warm 2-3 sentences in the requested locale, no jargon, no specs>",
          "anti_hallucination_notes": "<1 sentence: what was inferred vs explicitly visible>"
        }

        RULES:
        - NEVER assume manufacturer from visual patterns (R0-R13 anti-hallucination).
        - Aliases ONLY from visible labels / printed text.
        - Default to UNKNOWN when not explicit.
        - No fabricated specs (voltages, dimensions, torques) anywhere.
        - Summary: warm trusted-colleague voice, 2-3 sentences, plain language.
      PROMPT
      cache_control: { type: "ephemeral" }
    }
  ].freeze

  def self.user_content(binary:, content_type:, filename:, locale: nil)
    BatchChunkingPrompt.user_content(
      binary:       binary,
      content_type: content_type,
      filename:     filename,
      locale:       locale
    )
  end
end
