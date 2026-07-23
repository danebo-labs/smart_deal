# frozen_string_literal: true

require "digest"

# Specialized prompt for the field photo ingestion path (cost_v2, field_photo_v1).
# SYSTEM_BLOCKS: compact field-photo schema with explicit visual evidence.
# user_content: delegates to BatchChunkingPrompt.user_content for the image media block.
module FieldPhotoPrompt
  # Cache contract for live-photo diagnoses. Bump whenever the diagnostic
  # prompt or the cached response schema changes.
  CONTRACT_VERSION = "v1"

  # Independent contract version for the specialized photo path (no field_records
  # schema — explicit-evidence envelope instead). Versioned separately from
  # BatchChunkingPrompt so document-contract bumps don't invalidate photo dedup
  # and vice versa.
  # v2: acronym expansion and conventional-symbol recognition are not
  #     documented functions.
  # v3: port/line letter labels (P, T, M, L, BRK…) are acronyms too — no
  #     exceptions for "easy" ones.
  INGESTION_CONTRACT_VERSION = "field_photo_records_v3"

  def self.prompt_fingerprint_sha256
    @prompt_fingerprint_sha256 ||= Digest::SHA256.hexdigest(
      SYSTEM_BLOCKS.pluck(:text).join("\n")
    )
  end

  SYSTEM_BLOCKS = [
    {
      type: "text",
      text: <<~PROMPT.strip,
        ROLE: Senior Elevator Engineer parsing a FIELD PHOTO for technician RAG.
        This is a compact single-chunk path — NO S0-S18 report. Preserve useful
        technical knowledge when it is explicitly visible in the photo.

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
          "visible_text": ["<important printed text transcribed verbatim>", ...],
          "documented_functions": [
            {
              "label": "<visible identifier>",
              "function": "<function stated by a visible legend or printed text>",
              "evidence": "<exact visible legend/text supporting the function>"
            }
          ],
          "documented_connections": [
            {
              "from": "<visible endpoint label>",
              "to": "<visible endpoint label>",
              "evidence": "<unambiguous drawn line or printed connection text>"
            }
          ],
          "documented_values": [
            {
              "label": "<visible identifier>",
              "value": "<exact printed value>",
              "unit": "<exact printed unit or empty string>",
              "evidence": "<visible text supporting the value>"
            }
          ],
          "documented_warnings": ["<visible warning or instruction transcribed faithfully>", ...],
          "anti_hallucination_notes": "<1 sentence: what was inferred vs explicitly visible>"
        }

        RULES:
        - NEVER assume manufacturer from visual patterns (R0-R13 anti-hallucination).
        - Aliases ONLY from visible labels / printed text.
        - Default to UNKNOWN when not explicit.
        - No fabricated specs (voltages, dimensions, torques) anywhere.
        - Empty evidence arrays are correct for ordinary photos or unreadable diagrams.
        - A label, acronym, symbol, line position, or conventional schematic notation
          does NOT prove function. Record a function only when visible text or a visible
          legend explicitly states it IN WORDS. Acronym expansion (BRK→brake,
          P→pressure port, T→tank, RV→relief valve, ORF→orifice) and ISO-symbol
          recognition (motor circle, valve glyphs, pump symbols) are inference —
          when the only evidence is the label itself or the symbol shape, OMIT the
          function entirely.
        - This includes single-letter or port/line labels: P, T, M, L, BRK and
          similar. "Pressure port", "tank return", "motor", "brake line" are
          acronym expansions, NOT documented functions, unless the image prints
          the meaning in words (e.g. a legend reading "P = pressure"). Evidence
          that reads "Etiqueta impresa 'X'" can never support a function.
        - Record a connection only when both endpoint labels and the connecting path are
          unambiguous. If a line is hidden, crossed, cropped, or unclear, omit it.
        - Preserve printed values and units verbatim and associate them only with the
          label visibly attached to them.
        - Do not convert a visible condition into a repair, procedure, or safety rule.
        - If technical evidence is partially illegible, leave the affected item out and
          name the uncertainty in anti_hallucination_notes as REQUIRES_FIELD_VERIFICATION.
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
