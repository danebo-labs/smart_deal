# frozen_string_literal: true

module Rag
  # Adds a defining section for an explicit component id found in the
  # passages already selected. It does not retrieve, recurse, or guess.
  # A numeric match in a heading is not enough: the body has to share a
  # distinctive word with the sentence that names the id.
  class CompanionDefinitionExpander
    MAX_ADDED = 4
    MAX_ADDED_CHARS = 6_000
    HASH_ID = /#(\d+)/
    PIN_ID = /\bPin\s+(\d+)\b/i
    SINGLE_PAREN_ID = /(?<!#)\((\d+)\)/
    GENERIC = %w[
      senal entrada salida puerta sistema comprobar verificar activada activa
      activado activar bloqueada continuamente modulo control cuando donde
      desde hasta para como esta este estan valor permite ajustar ajuste
      debe puede sobre tiene estan esta
    ].freeze

    Result = Struct.new(:chunks, :added, :omitted, keyword_init: true)

    def self.expand(chunks, catalog:, targets: [])
      new(Array(chunks), catalog, Array(targets)).expand
    end

    def initialize(chunks, catalog, targets = [])
      @chunks = chunks
      @catalog = catalog
      @targets = targets
    end

    def expand
      if @catalog.nil?
        return Result.new(chunks: @chunks, added: [], omitted: missing_targets)
      end

      added = []
      omitted = []
      extra = []
      used = add_answer_targets(extra, added, omitted, 0)
      collect_mentions.each do |mention|
        break if extra.size >= MAX_ADDED

        decision = resolve(mention)
        if decision[:block].nil?
          omitted << decision[:omission]
          next
        end

        text = block_text(decision[:block])
        if used + text.length > MAX_ADDED_CHARS
          omitted << omission(mention, "budget", decision[:block])
          next
        end

        extra << chunk_for(decision[:block], mention, decision[:source])
        added << added_row(decision[:block], mention)
        used += text.length
      end
      Result.new(chunks: @chunks + extra, added: added, omitted: omitted.compact)
    end

    private

    def add_answer_targets(extra, added, omitted, used)
      @targets.each do |target|
        data = target.is_a?(Hash) ? target.stringify_keys : {}
        page = @catalog.page(data["document_key"], data["filename"])
        if page.nil?
          omitted << target_omission(data)
          next
        end

        row = page.to_h.stringify_keys
        next if loaded_page?(row)

        text = row["text"].to_s
        if extra.size >= MAX_ADDED || used + text.length > MAX_ADDED_CHARS
          omitted << target_omission(data)
          next
        end

        extra << target_chunk(row)
        added << {
          "context" => "answer_target",
          "item" => data["item"].to_s,
          "page" => row["page"].to_s,
          "filename" => row["filename"].to_s,
          "sha256" => Digest::SHA256.hexdigest(text)
        }
        used += text.length
      end
      used
    end

    def missing_targets
      @targets.map { |target| target_omission(target.is_a?(Hash) ? target.stringify_keys : {}) }
    end

    def target_omission(target)
      { "reason" => "target_not_loaded", "item" => target["item"].to_s }
    end

    def loaded_page?(page)
      body = page["text"].to_s.squish
      return true if body.blank?

      filename = page["filename"].to_s
      key = page["document_key"].to_s
      @chunks.any? { |chunk|
        meta = metadata(chunk)
        same_page = filename.present? && meta["filename"].to_s == filename &&
          [ meta["document_key"], meta["original_source_uri"], meta["document_id"] ].include?(key)
        same_page || content_of(chunk).squish.include?(body)
      }
    end

    def target_chunk(page)
      text = page["text"].to_s
      {
        content: text,
        metadata: {
          "canonical_name" => page["name"].to_s,
          "original_filename" => page["name"].to_s,
          "filename" => page["filename"].to_s,
          "document_key" => page["document_key"].to_s,
          "original_source_uri" => page["document_key"].to_s,
          "page_number" => page["page"].to_s,
          "content_sha256" => Digest::SHA256.hexdigest(text),
          "companion_context" => "answer_target",
          "provenance" => page["provenance"].to_s
        },
        identity_applicability: "compatible",
        companion_definition: true
      }
    end

    def collect_mentions
      grouped = {}
      order = []
      @chunks.each do |chunk|
        next unless citable?(chunk)

        key = document_key(chunk)
        next if key.blank?

        narrative = Rag::DocumentIdentityScope.omit_terminal_evidence_records(content_of(chunk))
        sentences(narrative).each do |sentence|
          ids_in(sentence).each do |id|
            unless grouped[id]
              order << id
              grouped[id] = { id: id, sentences: [], key: key, source: chunk }
            end
            next unless grouped[id][:key] == key

            grouped[id][:sentences] << sentence
          end
        end
      end
      order.map { |id| grouped[id] }
    end

    def resolve(mention)
      blocks = Array(@catalog.sections).select { |block| block["document_key"].to_s == mention[:key] }
      matches = blocks.select { |block| defines?(block, mention) }
      matches.reject! { |block| contained?(block) }
      if matches.empty?
        return { block: nil, omission: omission(mention, "no_match") }
      end
      if matches.size > 1
        return { block: nil, omission: omission(mention, "ambiguous", matches.first) }
      end

      { block: matches.first, source: mention[:source] }
    end

    def defines?(block, mention)
      return false unless Array(block["principal_ids"]).include?(mention[:id])

      Array(mention[:sentences]).any? do |sentence|
        (tokens(block["body"]) & tokens(sentence)).any?
      end
    end

    def contained?(block)
      body = block["body"].to_s.squish
      return false if body.length < 40

      @chunks.any? do |chunk|
        narrative = Rag::DocumentIdentityScope.omit_terminal_evidence_records(content_of(chunk)).squish
        narrative.include?(body)
      end
    end

    def sentences(text)
      text.to_s.split(/\n+/).flat_map { |line|
        stripped = line.strip
        # A bracketed index line packs unrelated keywords with several ids.
        # It is not a sentence that can confirm a definition.
        next [] if stripped.start_with?("[")

        stripped.split(/(?<=[.!?])\s+/)
      }.map(&:strip).reject(&:empty?)
    end

    def ids_in(sentence)
      found = sentence.scan(HASH_ID).flatten
      found.concat(sentence.scan(PIN_ID).flatten)
      found.concat(sentence.scan(SINGLE_PAREN_ID).flatten)
      found.map(&:to_i).uniq
    end

    def tokens(text)
      folded(text).split.filter_map { |token|
        next if token.length < 5 || GENERIC.include?(token) || token.match?(/\A\d+\z/)

        forms = [ token ]
        forms << token.delete_suffix("s") if token.end_with?("s") && token.length > 5
        forms
      }.flatten.uniq
    end

    def folded(text)
      I18n.transliterate(text.to_s).downcase.gsub(/[-_]/, "").gsub(/[^a-z0-9\s]/, " ")
    end

    def citable?(chunk)
      applicability = metadata(chunk)["identity_applicability"].presence ||
        chunk[:identity_applicability].to_s
      %w[reference_only unconfirmed_reference].exclude?(applicability)
    end

    def document_key(chunk)
      meta = metadata(chunk)
      meta["original_source_uri"].presence || meta["document_id"].presence
    end

    def content_of(chunk)
      chunk[:content].to_s
    end

    def metadata(chunk)
      chunk[:metadata].to_h.stringify_keys
    end

    def block_text(block)
      lines = []
      lines << block.dig("parent", "line") if block.dig("parent", "line").present?
      lines << block["line"]
      lines << block["body"] if block["body"].present?
      lines.join("\n").strip
    end

    def chunk_for(block, mention, source)
      meta = metadata(source)
      parent_number = block.dig("parent", "number")
      section = block["kind"] == "section" ? block["number"] : parent_number
      {
        content: block_text(block),
        metadata: meta.merge(
          "page_number" => block["page"].to_s,
          "section" => section.to_s,
          "section_heading" => block["line"].to_s,
          "parent_heading" => block.dig("parent", "line").to_s,
          "definition_of" => "##{mention[:id]}",
          "definition_provenance" => provenance(block, section)
        ),
        identity_applicability: source[:identity_applicability].presence || "compatible",
        companion_definition: true
      }
    end

    def provenance(block, section)
      [
        block["provenance"].presence,
        "página #{block['page']}",
        ("sección #{section}" if section.present?),
        "encabezado #{block['line']}"
      ].compact.join("; ")
    end

    def added_row(block, mention)
      {
        "definition_of" => "##{mention[:id]}",
        "page" => block["page"].to_s,
        "section" => (block["kind"] == "section" ? block["number"] : block.dig("parent", "number")).to_s,
        "heading" => block["line"].to_s,
        "provenance" => block["provenance"].to_s
      }
    end

    def omission(mention, reason, block = nil)
      {
        "reason" => reason,
        "definition_of" => "##{mention[:id]}",
        "heading" => block && block["line"].to_s
      }
    end
  end
end
