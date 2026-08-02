# frozen_string_literal: true

require "digest"

# Prompt for the T2 vision tier (docs/rag/plan_conocimiento_visual.md, Fase 5):
# reads the relations a page DRAWS, on pages where no vector geometry can be
# traced because the wiring, the terminal numbering, or both live inside a
# raster. T1 (TopologyEdgeDeriver) emits `[]` on 80 of the 98 pages of
# `SEGURIDADES 1.1-1.pdf`, and the dominant reason — 42.5 % of its rejections,
# dominant on 32 pages — is exactly that (I-15). Page 17 is the canonical case:
# ~15 relations with an explicit terminal number, and T1 sees none of them
# because `32 78 77 76 185 184…` are pixels.
#
# SCHEMA IS NOT NEW. `documented_connections` with `from` / `to` / `evidence` is
# lifted verbatim from FieldPhotoPrompt (app/prompts/field_photo_prompt.rb:55-61),
# and `canonical_component`, `label`, `anti_hallucination_notes` from the same
# envelope. A second grammar for the same fact would be a second thing to keep
# true.
#
# WHAT THIS PROMPT DELIBERATELY DOES NOT RECEIVE
#
# T1's already-traced edges. Gate B scores T2's precision and recall against
# those edges as free ground truth; a model shown the answer key measures the
# copier, not the reader. This is also why the T2 call is separate from the
# chunking call, which DOES get the layout digest (contract v8, Fase 4).
#
# INGESTION ONLY — never a runtime query path
# (docs/RAG_SEGURIDADES_BENCHMARK.md:109-115).
module VisionTopologyPrompt
  # Bump whenever the system text changes: Gate B iterates this prompt against a
  # measured threshold, and a measurement is only attributable to the exact text
  # that produced it. Logged with every call (VisionTopologyExtractor).
  CONTRACT_VERSION = "vision_topology_v1"

  def self.prompt_fingerprint_sha256
    @prompt_fingerprint_sha256 ||= Digest::SHA256.hexdigest(
      SYSTEM_BLOCKS.pluck(:text).join("\n")
    )
  end

  SYSTEM_BLOCKS = [
    {
      type: "text",
      text: <<~PROMPT.strip
        ROLE: Senior Elevator Engineer reading ONE page of a wiring/safety-chain
        document to record the connections the page visibly DRAWS. Output feeds a
        safety-critical technician RAG: a connection that is not on the page is
        the worst failure this system can produce. Recording nothing is always
        safer than recording a plausible guess.

        Return ONLY a single valid JSON object — no markdown, no prose.
        Schema:
        {
          "documented_connections": [
            {
              "from": "<visible endpoint label, transcribed exactly>",
              "to": "<visible endpoint label, transcribed exactly>",
              "evidence": "<the drawn conductor or printed text that proves it: colour/route and both ends>"
            }
          ],
          "documented_components": [
            {
              "label": "<printed label naming the part>",
              "canonical_component": "<3-5 word name of what the picture shows>",
              "evidence": "<what in the picture supports that name>"
            }
          ],
          "anti_hallucination_notes": "<1 sentence: what was read directly vs what stayed unreadable>"
        }

        WHAT COUNTS AS A CONNECTION
        - A conductor drawn on the page that you can follow from one end to the
          other, or printed text that states the connection. Nothing else.
        - Terminal numbers printed inside the picture of a terminal strip ARE
          readable evidence — transcribe the digits exactly as printed.
        - Follow the conductor. Two things being near each other, aligned in a
          column, the same colour, or listed in the same row is NOT a connection.
        - If either end disappears behind a graphic, is cut off, or you cannot
          read it with certainty, OMIT the relation. Do not guess the endpoint.

        HOW TO NAME AN ENDPOINT
        - Transcribe what is printed, verbatim: a device label, a connector name,
          or a terminal number. Never invent, translate, expand, normalise or
          correct a label, including obvious-looking typos.
        - NEVER expand an acronym and NEVER name a manufacturer, model or
          standard that is not printed on the page.
        - A conventional schematic symbol is not a documented function: recognising
          what a symbol usually means is not reading what this page says.

        WHAT `from` AND `to` DO NOT MEAN
        - They are an unordered PAIR, not a direction: nothing in a drawn wire
          says which end is the source. Never write evidence as "A feeds B",
          "A powers B" or "A controls B".
        - They are not exhaustive: a conductor may pass through further devices
          between the two ends you name. If you can see intermediate devices on
          the same run, name them in `evidence`; never imply the run has only two
          elements.

        CROPS
        Each crop is one small graphic of this page framed together with the
        printed label adjacent to it, and the label is stated in the text block
        beside it. Use crops to read what the full page is too small to show —
        the identity of a small part, digits on a terminal, the end of a wire.
        The label given with a crop is the label the page prints next to that
        graphic; it is a fact about placement, not a claim about function.

        LANGUAGE
        - Endpoint labels are transcriptions: they keep the page's own spelling
          whatever language it is in, typos included.
        - Write every `evidence` and `canonical_component` value in the language
          the user turn asks for; with no request, use the language printed on the
          page. This string is quoted back to a technician beside the
          deterministically derived evidence of the same document, so it cannot
          arrive in a different language from the page it describes.

        OUTPUT DISCIPLINE
        - `[]` for `documented_connections` is a correct, expected and frequent
          answer — divider pages, cover pages and photo-only pages have none.
        - One entry per pair. Do not repeat the same pair from a second wire.
        - Do not transcribe the page, summarise it, or describe its layout.
        - `documented_components` only for parts you can actually name from the
          picture; omit the entry rather than restate the label as the name.
      PROMPT
    }
  ].freeze

  # Builds the user turn: the full page, then one image + one text block per
  # crop, then the instruction.
  #
  # @param page        [PdfPageRasterizer::Raster] full-page render
  # @param crops       [Array<Hash>] { raster: Raster, label: String }
  # @param page_number [Integer]
  # @param total_pages [Integer]
  # @param filename    [String] context hint only
  # @param locale      [String, nil] ISO 639-1 for the `evidence` prose, same
  #   convention BatchChunkingPrompt uses for `summary`. Endpoint labels are
  #   never translated — they are transcriptions
  # @return [Array<Hash>]
  def self.user_content(page:, crops:, page_number:, total_pages:, filename:, locale: nil)
    blocks = [ image_block(page), { type: "text", text: "FULL PAGE #{page_number} of #{total_pages}." } ]

    Array(crops).each_with_index do |crop, index|
      raster = crop[:raster] || crop["raster"]
      label  = (crop[:label] || crop["label"]).to_s
      next unless raster

      blocks << image_block(raster)
      blocks << {
        type: "text",
        text: "CROP #{index + 1} of page #{page_number} — printed label adjacent to this graphic: #{label}"
      }
    end

    instruction = +"Record the connections page #{page_number} visibly draws, and the small components " \
      "you can name from the crops. Source file (context only, never an endpoint name): #{filename}."
    instruction << " Evidence language: #{locale}." if locale.present?
    instruction << " Return the JSON object and nothing else."

    blocks << { type: "text", text: instruction }
    blocks
  end

  def self.image_block(raster)
    {
      type: "image",
      source: { type: "base64", media_type: raster.media_type, data: raster.data }
    }
  end
  private_class_method :image_block
end
