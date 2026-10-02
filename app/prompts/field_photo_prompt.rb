# frozen_string_literal: true

require "digest"

# Specialized prompt for the field photo ingestion path (cost_v2, field_photo_v1).
# SYSTEM_BLOCKS: compact field-photo schema with explicit visual evidence.
# user_content: image media block, plus bounded VisualTaskContext on the
# live Field Companion path only. Ingestion callers omit that argument.
# SYSTEM_BLOCKS stay the ingestion contract. Context in the user block is
# not evidence and is never copied into manufacturer, model, or visible text.
module FieldPhotoPrompt
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

        LANGUAGE:
        - Write canonical_component, summary, anti_hallucination_notes, and the
          "function" text inside documented_functions/documented_warnings in the
          locale given by the "Summary language: <code>" hint in the user content.
          Default to Spanish when that hint is absent. This is an absolute requirement,
          not a style preference — never fall back to English prose when the
          requested locale is Spanish.
        - aliases, visible_text, and every "evidence" field (documented_functions,
          documented_connections, documented_values) are verbatim transcriptions of
          what is printed/visible — never translate or paraphrase these, regardless
          of the requested locale.
        - manufacturer, model, subsystem, and condition are fixed enum values or
          verbatim visible text as defined in the schema above — locale does not
          apply to them.

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

  def self.user_content(binary:, content_type:, filename:, locale: nil, visual_task_context: nil)
    blocks = BatchChunkingPrompt.user_content(
      binary:       binary,
      content_type: content_type,
      filename:     filename,
      locale:       locale
    )
    context = Rag::VisualTaskContext.coerce(visual_task_context)
    return blocks unless context&.relevance_anchor?

    blocks + [ { type: "text", text: context_block(context) } ]
  end

  def self.context_block(context)
    json = JSON.generate(context.to_h)
    if context.visual_task?
      visual_task_block(json)
    else
      active_work_block(json)
    end
  end
  private_class_method :context_block

  def self.visual_task_block(json)
    <<~TEXT.strip
      Active work context (not evidence and not a manual):
      #{json}
      CONTEXT IS NOT EVIDENCE. Never copy a manufacturer, model, code, condition, or printed value from this context. Read them only from what is explicitly visible in the image.
      The primary relevance anchor is visual_task.
      Add three keys to the same JSON object:
      "target_visible": true | false | null   — does this image show the part or assembly named by visual_task?
      "relevance_to_goal": "relevant" | "unrelated" | "uncertain"
      "missing_view_or_detail": "<one short optional request in the summary language, starting with the equivalent of 'If you can', naming the view or detail that would improve accuracy; empty string when no additional evidence would help>"
      Use "summary" to answer the intent only as far as this image safely supports: say what is visible relative to visual_task, state the exact knowledge boundary, and, when appropriate, give one non-invasive component-specific check limited to looking, reading, or listening. Additional evidence improves accuracy; never say another photo, a nameplate, or a manual is required before you can help.
      Never take a manufacturer, model, code, or value from the context. Do not give torque, settings, turn counts, target values, equipment-specific adjustment procedures, or critical manufacturer-specific instructions.
    TEXT
  end
  private_class_method :visual_task_block

  def self.active_work_block(json)
    <<~TEXT.strip
      Active work context (not evidence and not a manual):
      #{json}
      CONTEXT IS NOT EVIDENCE. Never copy a manufacturer, model, code, condition, or printed value from this context. Read them only from what is explicitly visible in the image.
      There is no visual task. Judge whether this image belongs to the active work (goal, equipment_context, pending). A photo can belong to that work without showing a specifically requested part.
      Add these keys to the same JSON object:
      "relevance_to_goal": "relevant" | "unrelated" | "uncertain"
      — relevant when the image shows a part, nameplate, display, or assembly of that work, even if the fault itself is not in frame
      — uncertain when it is not clear that the image belongs to that work
      — unrelated when the image is a different job
      "target_visible": null
      "missing_view_or_detail": ""
      Do not give torque, settings, turn counts, target values, equipment-specific adjustment procedures, or critical manufacturer-specific instructions.
    TEXT
  end
  private_class_method :active_work_block
end
