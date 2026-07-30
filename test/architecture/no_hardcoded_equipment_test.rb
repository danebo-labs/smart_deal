# frozen_string_literal: true

require "test_helper"
require "ripper"

# Fase 6 gate for docs/RAG_REGEX_AUDIT_FASE05_2026-07-29.md §6:
#
#   "Ningún caso nuevo del benchmark puede resolverse agregando al código
#   productivo el nombre de un fabricante, un modelo, una placa, un
#   identificador o una relación técnica concreta."
#
# Two independent checks:
#
#   A. Executable scan: no string/regexp LITERAL in the "núcleo estricto"
#      (app/services/rag/*, bedrock_rag_service.rb, rag_retrieval_profile.rb)
#      names a known manufacturer/model outside ALLOWED_MANUFACTURER_LITERAL.
#      Comments are exempt by construction — Ripper only yields string/regexp
#      *content* tokens, never comment tokens.
#   B. Frozen ceiling: KNOWN_HARDCODED_LOCATIONS documents the five sites the
#      Fase 0.5 audit (§3.1, R1-R5) already found and froze pending Fase 2/P1.
#      Its size can only shrink (a retirement removes a row); growing it past
#      MAX_ALLOWLIST_SIZE requires bumping that constant in the same PR, which
#      is the "justificación en el PR" the audit doc requires for a new row.
#
# This guardian does NOT retire R1-R5 itself — that is P4/P5/P6, gated on
# Fase 2's metadata backfill. It only prevents the set from growing silently.
class NoHardcodedEquipmentTest < ActiveSupport::TestCase
  CORE_FILES = (
    Rails.root.glob("app/services/rag/*.rb").map(&:to_s) +
    [
      Rails.root.join("app/services/bedrock_rag_service.rb").to_s,
      Rails.root.join("app/services/rag_retrieval_profile.rb").to_s
    ]
  ).freeze

  # Corpus manufacturers/models a generic selector must never need to name in
  # productive code (plan §2 ground truth + Fase 0.5 H2). Includes the eight
  # already inside EXPLICIT_EQUIPMENT_PATTERN plus the four the audit found
  # missing from it — CTA/Elecmegon/ENIER/TOKIBAT never belong in code either,
  # named or not.
  KNOWN_MANUFACTURERS = %w[
    ALTIUS ORONA KONE OTIS SCHINDLER SOPREL THYSSENKRUPP THYSSEN
    CTA ELECMEGON ENIER TOKIBAT EDEL HIDRA SISTEL ALJO MR08 MICONIC SMART
  ].freeze
  MANUFACTURER_PATTERN = Regexp.union(
    KNOWN_MANUFACTURERS.map { |name| /\b#{name}\b/i } + [ /CARLOS\s+SILVA/i ]
  ).freeze

  # docs/RAG_REGEX_AUDIT_FASE05_2026-07-29.md §3.1 — the only site that
  # currently fails check A. Growing this array requires bumping
  # MAX_ALLOWLIST_SIZE below in the same PR.
  ALLOWED_MANUFACTURER_LITERAL = [
    { file: "app/services/rag/deterministic_intent.rb", constant: "EXPLICIT_EQUIPMENT_PATTERN" } # R1
  ].freeze

  # §3.1 in full — R2-R5 do not hardcode a manufacturer *name* (they hardcode
  # a lexical shape or a single technical relation), so they never trip check
  # A, but they are exactly the domain-knowledge-in-code sites Fase 6 targets.
  # Each row is a canary: if the identifier stops existing at its file (the
  # retirement the audit prescribes), review must delete that row — which is
  # how "sólo puede decrecer" happens in practice.
  KNOWN_HARDCODED_LOCATIONS = [
    { file: "app/services/rag/deterministic_intent.rb", identifier: "EXPLICIT_EQUIPMENT_PATTERN", blocked_by: "Fase 2" }, # R1
    { file: "app/services/rag/ambiguous_model_responder.rb", identifier: "MODEL_PATTERN", blocked_by: "nada — P1" },     # R2
    { file: "app/services/rag/answer_safety_processor.rb", identifier: "board_model_name?", blocked_by: "Fase 2" },      # R3
    { file: "app/services/rag/answer_safety_processor.rb", identifier: "DEVICE_FUNCTION_CLAIM_PATTERN", blocked_by: "Fase 1" }, # R4
    { file: "app/services/bedrock_rag_service.rb", identifier: "query_names_different_document?", blocked_by: "ya disponible" } # R5
  ].freeze
  MAX_ALLOWLIST_SIZE = 5

  test "no core RAG file names a known manufacturer/model in a string or regexp literal outside the allowlist" do
    violations = CORE_FILES.flat_map { |file| manufacturer_literals_in(file) }
      .reject { |hit| allowlisted?(hit) }

    assert_empty violations, <<~MSG
      Literal de fabricante/modelo fuera de la allowlist congelada (docs/RAG_REGEX_AUDIT_FASE05_2026-07-29.md §6):
      #{violations.map { |hit| "  #{hit[:file]}:#{hit[:line]} #{hit[:content].inspect}" }.join("\n")}
      Un caso nuevo del benchmark nunca se resuelve nombrando un fabricante/modelo en código productivo:
      el defecto está en la metadata o en el selector de evidencia.
    MSG
  end

  test "KNOWN_HARDCODED_LOCATIONS never grows past the frozen ceiling" do
    assert_operator KNOWN_HARDCODED_LOCATIONS.size, :<=, MAX_ALLOWLIST_SIZE,
      "la allowlist R1-R5 solo puede decrecer — agregar una fila requiere subir MAX_ALLOWLIST_SIZE " \
      "en el mismo PR, con justificación (docs/RAG_REGEX_AUDIT_FASE05_2026-07-29.md §6)"
  end

  test "each KNOWN_HARDCODED_LOCATIONS row still points at a real identifier" do
    KNOWN_HARDCODED_LOCATIONS.each do |entry|
      source = Rails.root.join(entry[:file]).read
      pattern = /(?:def\s+#{Regexp.escape(entry[:identifier])}[(\s]|#{Regexp.escape(entry[:identifier])}\s*=)/
      assert_match pattern, source,
        "#{entry[:file]} ya no define #{entry[:identifier]}: si se retiró (bloqueado por #{entry[:blocked_by]}), " \
        "borra esta fila de KNOWN_HARDCODED_LOCATIONS en vez de dejarla obsoleta"
    end
  end

  private

  def manufacturer_literals_in(file)
    source = File.read(file)
    hits = []
    in_literal = false
    buffer = +""
    start_line = nil

    Ripper.lex(source).each do |(pos, type, tok, _state)|
      case type
      when :on_tstring_beg, :on_regexp_beg, :on_words_beg, :on_symbeg
        in_literal = true
        buffer = +""
        start_line = pos[0]
      when :on_tstring_content, :on_words_sep
        buffer << tok if in_literal
      when :on_tstring_end, :on_regexp_end, :on_label_end
        if in_literal && buffer.match?(MANUFACTURER_PATTERN)
          hits << { file: relative(file), line: start_line, content: buffer }
        end
        in_literal = false
      end
    end

    hits
  end

  def allowlisted?(hit)
    ALLOWED_MANUFACTURER_LITERAL.any? do |entry|
      next false unless entry[:file] == hit[:file]

      definition_line = Rails.root.join(entry[:file]).readlines
        .find_index { |line| line.include?("#{entry[:constant]} =") }
      definition_line && (hit[:line] - 1).between?(definition_line, definition_line + 5)
    end
  end

  def relative(file)
    Pathname.new(file).relative_path_from(Rails.root).to_s
  end
end
