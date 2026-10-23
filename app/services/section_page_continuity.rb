# frozen_string_literal: true

# Joins a page that opens in the middle of an item to the previous page's
# open item. A heading that does not describe its fragment is replaced with
# the section and item that do. The PDF index and the printed page number
# stay distinct. Aliases of the following item are not copied onto the
# continuation; an alias that only the moved text contains moves with it.
# Field records are rendered by BatchResultsParserService.
# This class does not name a manual or a symptom.
class SectionPageContinuity
  CONTINUATION_HEADING = "(continuación de página anterior)"
  SECTION_LINE = /\A\d{1,2}(?:\.\d{1,2})+\s+\p{L}/
  ITEM_LINE = /\A[•●▪]\s+\S/
  CHECK_LINE = /\A[–—-]\s+\S/
  PRINTED_PAGE = /(?:p[aá]g(?:ina)?|page)\.?\s*(\d{1,4})\s*(?:\/|de|of)\s*(\d{1,4})/i
  CONDITIONAL = /\b(?:en caso|si)\b/i
  ALIAS_WORDS = 9
  ARTICLES = %w[el la los las un una unos unas].freeze
  RESULT_PATTERN = %r{<search_result>\n<content>\n(.*?)\n</content>\n<source>\n(.*?)\n</source>}m

  def self.apply!(chunks, page_texts: nil, extra_records: nil, isolate: false, keep_internal: false)
    new.apply!(
      chunks,
      page_texts: page_texts,
      extra_records: extra_records,
      isolate: isolate,
      keep_internal: keep_internal
    )
  end

  def self.repair_prompt(prompt, pages:, extra_records: [], isolate: true)
    new.repair_prompt(prompt, pages: pages, extra_records: extra_records, isolate: isolate)
  end

  def apply!(chunks, page_texts: nil, extra_records: nil, isolate: false, keep_internal: false)
    pages = normalize_pages(page_texts)
    grouped = Hash.new { |hash, key| hash[key] = [] }
    list = Array(chunks)
    list.each do |chunk|
      next unless chunk.is_a?(Hash)

      grouped[chunk["page"].to_i] << chunk
    end
    numbers = grouped.keys.select(&:positive?).sort
    notes = []
    numbers.each_cons(2) do |left, right|
      next unless right == left + 1

      note = stitch_pair(
        grouped[left].last,
        grouped[right].first,
        left,
        right,
        pages,
        Array(extra_records),
        isolate,
        list
      )
      notes << note if note
    end
    release_internal!(list) unless keep_internal
    { "chunks" => list, "notes" => notes }
  end

  def repair_prompt(prompt, pages:, extra_records: [], isolate: true)
    text = utf8(prompt)
    matches = text.to_enum(:scan, RESULT_PATTERN).map { Regexp.last_match }
    return { "prompt" => text, "blocked" => "no search results", "notes" => [] } if matches.empty?

    page_map = normalize_pages(pages)
    chunks = matches.map { |match| pseudo_chunk(match[1], page_map) }
    outcome = apply!(chunks, page_texts: page_map, extra_records: extra_records, isolate: isolate, keep_internal: true)
    joined = outcome["notes"].find { |note| note["joined"] }
    return { "prompt" => text, "blocked" => outcome["notes"].last&.dig("blocked") || "no consecutive opening", "notes" => outcome["notes"] } unless joined

    rebuilt = text.dup
    matches.each_with_index do |match, index|
      chunk = chunks[index]
      next unless chunk["_changed"]

      replacement = assemble_content(chunk)
      needle = match[0]
      raise "content duplicated" unless rebuilt.scan(needle).size == 1

      rebuilt = rebuilt.sub(needle, needle.sub(match[1], replacement))
    end
    {
      "prompt" => rebuilt,
      "blocked" => nil,
      "notes" => outcome["notes"],
      "joined" => joined
    }
  end

  private

  def stitch_pair(parent, child, left, right, pages, extra_records, isolate, chunks)
    return nil unless parent.is_a?(Hash) && child.is_a?(Hash)

    child_page = pages[right]
    return { "blocked" => "next page has a heading", "pdf_page" => right } if child_page && !opens_mid_item?(child_page[:body])

    prefix = leading_prefix(child["text"].to_s)
    opening = child_page ? page_opening(child_page[:body]) : nil
    if opening.present? && prefix.present? && !same_text?(opening, prefix)
      return { "blocked" => "opening does not match the chunk", "pdf_page" => right }
    end
    moved_text = prefix.presence || opening
    return { "blocked" => "no leading continuation", "pdf_page" => right } if moved_text.blank?
    return { "blocked" => "already joined", "pdf_page" => right } if norm(parent["text"]).include?(norm(moved_text))

    parent_page = pages[left]
    section = section_before_item(parent_page&.dig(:body), last_item(parent["text"]))
    item = last_item(parent["text"])
    heading = fragment_heading(section, item)
    original_child_records = Array(child["field_records"]).map(&:dup)
    original_child_record_text = child["_record_text"]

    remainder = strip_prefix(child["text"].to_s, prefix.presence || moved_text)
    parent["text"] = joined_parent_text(parent["text"], left, right, parent_page, child_page, section, moved_text)
    child["text"] = remainder
    moved_aliases = carry_aliases!(parent, child, moved_text, remainder)
    parent.delete("_record_text")
    parent["_changed"] = true
    child["_changed"] = true

    moved, kept = partition_records(original_child_records, moved_text, remainder)
    attached = attach_extra(extra_records, moved_text, remainder, parent["field_records"])
    rejected = attached[:rejected]
    carried = (moved + attached[:kept]).map { |record| record.merge("source_pdf_page" => right) }
    parent["field_records"] = retarget_records(Array(parent["field_records"]) + carried, parent["text"], heading, left)
    child["field_records"] = if isolate
      restore_isolated(original_child_records, moved_text)
    else
      retarget_records(kept, remainder, heading_for_remainder(remainder, section), right)
    end
    if isolate && moved.empty?
      child["_record_text"] = original_child_record_text
    else
      child.delete("_record_text")
    end
    drop_empty_child!(chunks, child) if remainder.blank? && !keep_prompt_child?(child)

    {
      "joined" => true,
      "pdf_pages" => [ left, right ],
      "printed_pages" => [ parent_page&.dig(:printed), child_page&.dig(:printed) ],
      "section" => section,
      "item" => item,
      "heading" => heading,
      "moved_records" => moved.size + attached[:kept].size,
      "moved_aliases" => moved_aliases,
      "rejected_records" => rejected,
      "isolated" => isolate
    }
  end

  # An alias found only in the moved text follows it to the parent. The slots
  # it frees go to the items that stay in the child, so the child is still
  # found by its own symptoms.
  def carry_aliases!(parent, child, moved_text, remainder)
    return [] unless child["aliases"].is_a?(Array)

    moved = child["aliases"].select do |name|
      phrase?(moved_text, name) && !phrase?(remainder, name)
    end
    return [] if moved.empty?

    parent["aliases"] = merge_aliases(Array(parent["aliases"]), moved)
    kept = child["aliases"] - moved
    items = remainder.to_s.lines.map { |line| flatten(line) }.grep(ITEM_LINE).map { |line| item_alias(line) }
    child["aliases"] = merge_aliases(kept, items)
    moved
  end

  def merge_aliases(current, extra)
    seen = current.map { |name| norm(name) }
    added = extra.select do |name|
      key = norm(name)
      next false if key.blank? || seen.include?(key)

      seen << key
    end
    (current + added).first(BatchResultsParserService::CHUNK_ALIAS_LIMIT)
  end

  def item_alias(line)
    words = line.sub(/\A[•●▪]\s+/, "").sub(/[.:;]+\z/, "").split
    words = words.reject { |word| ARTICLES.include?(word.downcase) } if words.size > ALIAS_WORDS
    words.first(ALIAS_WORDS).join(" ")
  end

  def phrase?(text, name)
    needle = norm(name)
    needle.present? && " #{norm(text)} ".include?(" #{needle} ")
  end

  def pseudo_chunk(content, pages)
    header, narrative, record_text = split_content(content)
    page = best_page(narrative, pages)
    {
      "page" => page,
      "text" => narrative,
      "field_records" => parse_rendered_records(record_text),
      "_header" => header,
      "_record_text" => record_text,
      "_original" => content,
      "_changed" => false
    }
  end

  def split_content(content)
    header = ""
    rest = content.to_s
    if (match = rest.match(/\A(.*?\n\[SEARCH_ALIASES:.*\]\n\n)/m))
      header = match[1]
      rest = match.post_match
    end
    marker = "# FIELD-SAFETY EVIDENCE RECORDS"
    narrative, _, records = rest.partition(marker)
    record_text = records.present? ? "#{marker}#{records}" : ""
    [ header, narrative.strip, record_text.strip ]
  end

  def assemble_content(chunk)
    header = chunk["_header"].to_s
    narrative = chunk["text"].to_s.strip
    records = if chunk.key?("_record_text") && chunk["_record_text"].present?
      chunk["_record_text"]
    else
      render_records(chunk["field_records"], chunk["page"])
    end
    body = [ narrative, records ].compact_blank.join("\n\n")
    "#{header}#{body}"
  end

  def joined_parent_text(text, left, right, parent_page, child_page, section, continuation)
    body = text.to_s.strip
    prefix = []
    parent_marks = page_marks(left, parent_page&.dig(:printed))
    prefix << parent_marks unless body.include?("[PDF_PAGE: #{left}]")
    prefix << section if section.present? && body.exclude?(section)
    head = prefix.compact_blank.join("\n")
    body = "#{head}\n\n#{body}" if head.present?
    tail = "#{page_marks(right, child_page&.dig(:printed))}\n#{continuation.to_s.strip}"
    "#{body.rstrip}\n\n#{tail}\n"
  end

  def page_marks(pdf_page, printed)
    lines = [ "[PDF_PAGE: #{pdf_page}]" ]
    lines << "[PRINTED_PAGE: #{printed}]" if printed.present?
    lines.join("\n")
  end

  def leading_prefix(text)
    lines = text.to_s.lines
    index = 0
    index += 1 while index < lines.size && skip_line?(lines[index])
    return nil unless lines[index]&.strip&.match?(CHECK_LINE)

    finish = index
    while finish < lines.size
      stripped = lines[finish].strip
      break if stripped.match?(ITEM_LINE) || stripped.match?(SECTION_LINE) || stripped.start_with?("# ")

      finish += 1
    end
    return nil if finish == index

    lines[index...finish].join.strip
  end

  def strip_prefix(text, prefix)
    return text.to_s.strip if prefix.blank?

    remainder = text.to_s.sub(prefix, "")
    remainder.sub(/\A\s+/, "")
  end

  def page_opening(body)
    lines = body.to_s.lines
    index = 0
    index += 1 while index < lines.size && skip_line?(lines[index])
    return nil unless lines[index]&.strip&.match?(CHECK_LINE)

    taken = []
    lines[index..].each do |line|
      flat = flatten(line)
      next if flat.empty?
      break if flat.match?(ITEM_LINE) || flat.match?(SECTION_LINE)

      taken << flat
    end
    taken.join(" ").strip.presence
  end

  def opens_mid_item?(body)
    line = body.to_s.lines.map { |item| flatten(item) }.find(&:present?)
    line.present? && line.match?(CHECK_LINE)
  end

  def skip_line?(line)
    stripped = line.to_s.strip
    stripped.empty? || stripped.match?(/\A\[(?:PDF_PAGE|PRINTED_PAGE):/)
  end

  def last_item(text)
    text.to_s.lines.map { |line| flatten(line) }.grep(ITEM_LINE).last
  end

  def section_before_item(body, item)
    return nil if body.blank? || item.blank?

    target = norm(item)
    current = nil
    body.to_s.lines.each do |line|
      flat = flatten(line)
      next if flat.empty?

      current = flat if flat.match?(SECTION_LINE)
      return current if norm(flat).include?(target)
    end
    current
  end

  def fragment_heading(section, item)
    section_text = section.to_s.strip
    item_text = item.to_s.sub(/\A[•●▪]\s+/, "").strip
    return item_text if section_text.blank?
    return section_text if item_text.blank?

    "#{section_text} — #{item_text}"
  end

  def keep_prompt_child?(child)
    child["_header"].present? || child["_original"].present?
  end

  def drop_empty_child!(chunks, child)
    return if Array(child["field_records"]).any? || Array(child["topology_edges"]).any?

    chunks.delete(child)
  end

  def release_internal!(chunks)
    chunks.each do |chunk|
      next unless chunk.is_a?(Hash)

      chunk.keys.grep(/\A_/).each { |key| chunk.delete(key) }
      next unless chunk["field_records"].is_a?(Array)

      chunk["field_records"] = chunk["field_records"].map { |record|
        values = record.deep_stringify_keys.except("_page")
        origin = positive_page(values["source_pdf_page"])
        origin ? values.merge("source_pdf_page" => origin) : values.except("source_pdf_page")
      }
    end
  end

  def heading_for_remainder(text, carried_section)
    item = last_item(text)
    section = section_before_item(text, item) || carried_section
    fragment_heading(section, item)
  end

  def partition_records(records, moved_text, remainder)
    moved = []
    kept = []
    Array(records).each do |record|
      evidence = record["ev"].to_s
      if evidence.present? && contains_text?(moved_text, evidence) && !contains_text?(remainder, evidence)
        moved << record
      else
        kept << record
      end
    end
    [ moved, kept ]
  end

  def attach_extra(records, moved_text, remainder, existing)
    kept = []
    rejected = []
    seen = Array(existing).map { |record| norm(record["ev"]) }
    Array(records).each do |record|
      next unless record.is_a?(Hash)

      values = record.deep_stringify_keys
      evidence = values["ev"].to_s
      next if evidence.blank? || seen.include?(norm(evidence))
      next unless contains_text?(moved_text, evidence) && !contains_text?(remainder, evidence)
      unless admitted_record?(values) && faithful_record?(moved_text, values)
        rejected << "unfaithful or untyped record"
        next
      end

      kept << values.slice(*BatchResultsParserService::FIELD_RECORD_ALLOWED_KEYS)
      seen << norm(evidence)
    end
    { kept: kept, rejected: rejected }
  end

  def admitted_record?(values)
    BatchResultsParserService::FIELD_RECORD_TYPES.include?(values["k"].to_s)
  end

  # A conditional continuation stays conditional. A lossy parse is not rewritten
  # into an unconditional action or an observed fact.
  def faithful_record?(continuation, values)
    action = values["a"].to_s
    result = values["r"].to_s
    return false if conditional?(continuation) && !conditional?(action)
    return false if conditional_result?(continuation) && result != "DATA_NOT_AVAILABLE" && !conditional?(result)

    true
  end

  def conditional?(text)
    text.to_s.match?(CONDITIONAL)
  end

  def conditional_result?(text)
    sentences = text.to_s.split(/(?<=[.!?])\s+/)
    outcome = sentences.drop(1).join(" ")
    outcome.present? && conditional?(outcome)
  end

  def retarget_records(records, fragment, fallback, default_page)
    Array(records).map do |record|
      values = record.deep_stringify_keys
      legacy = positive_page(values.delete("_page"))
      origin = positive_page(values["source_pdf_page"]) || legacy
      if origin && origin != default_page.to_i
        values["source_pdf_page"] = origin
      else
        values.delete("source_pdf_page")
      end
      heading = heading_for_evidence(fragment, values["ev"], fallback)
      values["h"] = heading if heading.present? && !describes?(values["h"], fragment)
      values
    end
  end

  def restore_isolated(records, moved_text)
    Array(records).reject { |record| contains_text?(moved_text, record["ev"]) }
  end

  def heading_for_evidence(fragment, evidence, fallback)
    return fallback if evidence.blank?

    section = nil
    item = nil
    fragment.to_s.lines.each do |line|
      flat = flatten(line)
      next if flat.empty? || flat.match?(/\A\[(?:PDF_PAGE|PRINTED_PAGE):/)

      section = flat if flat.match?(SECTION_LINE)
      item = flat if flat.match?(ITEM_LINE)
      return fragment_heading(section, item) if contains_text?(flat, evidence)
    end
    fallback
  end

  def describes?(heading, fragment)
    text = heading.to_s.strip
    return false if text.blank? || text.casecmp?(CONTINUATION_HEADING)

    words = tokens(text).select { |word| word.length >= 4 }
    return false if words.empty?

    other = tokens(fragment)
    words.count { |word| other.include?(word) }.to_f / words.size >= 0.6
  end

  def render_records(records, default_page)
    blocks = Array(records).filter_map do |record|
      values = record.deep_stringify_keys
      values.delete("_page")
      clean = values.slice(*BatchResultsParserService::FIELD_RECORD_ALLOWED_KEYS)
      origin = positive_page(values["source_pdf_page"])
      clean["source_pdf_page"] = origin if origin
      next if clean["k"].blank? || clean["ev"].blank?

      parser.send(:render_field_record, clean, page: default_page)
    end
    return "" if blocks.empty?

    "# FIELD-SAFETY EVIDENCE RECORDS\n\n#{blocks.join("\n\n")}\n"
  end

  def parse_rendered_records(text)
    text.to_s.split(/(?=^FIELD_RECORD:)/).filter_map do |part|
      next unless part.include?("END_FIELD_RECORD")

      values = {
        "k" => part[/^RECORD_TYPE:\s*(.+)$/, 1],
        "h" => part[/^SOURCE_SECTION_OR_PAGE:\s*(.+)$/, 1],
        "a" => part[/^ACTION:\s*(.+)$/, 1],
        "r" => part[/^EXPECTED_RESULT:\s*(.+)$/, 1],
        "ev" => part[/^EVIDENCE:\s*(.+)$/, 1]
      }
      details = part[/^DETAILS:\s*(.+)$/, 1]
      uncertainty = part[/^UNCERTAINTY:\s*(.+)$/, 1]
      authority = part[/^REPAIR_AUTHORITY:\s*(.+)$/, 1]
      values["x"] = details if details.present?
      values["u"] = uncertainty if uncertainty.present?
      values["ra"] = authority if authority.present?
      trigger = part[/^STOP_WORK_TRIGGER:\s*(.+)$/, 1]
      action = part[/^STOP_WORK_REQUIRED_ACTION:\s*(.+)$/, 1]
      values["sw"] = [ trigger, action ] if trigger.present? && action.present?
      values.compact
    end
  end

  def normalize_pages(page_texts)
    pending = {}
    ready = {}
    Array(page_texts).each do |number, raw|
      if raw.is_a?(Hash) && raw[:body].is_a?(String)
        ready[number.to_i] = raw
        next
      end
      next if raw.blank?

      text = utf8(raw)
      pending[number.to_i] = { raw: text, printed: printed_label(text) }
    end
    catalog = {}
    pending.each { |number, page| catalog[number] = page[:raw] }
    ready.each { |number, page| catalog[number] = page[:raw] || page[:body] }
    running = Rag::PageChunkFidelity.running_matter_lines(catalog)
    pending.each do |number, page|
      page[:body] = Rag::PageChunkFidelity.strip_running_matter(page[:raw], running_lines: running)
      ready[number] = page
    end
    ready
  end

  def positive_page(value)
    number = Integer(value, exception: false)
    number if number&.positive?
  end

  def printed_label(raw)
    matches = raw.to_s.scan(PRINTED_PAGE)
    return nil if matches.empty?

    number, total = matches.last
    "#{number.to_i}/#{total.to_i}"
  end

  def best_page(body, pages)
    scored = pages.map { |number, page| [ overlap_score(body, page[:body]), number ] }
    score, number = scored.max_by { |row| row[0] }
    score.to_i >= 2 ? number : nil
  end

  def overlap_score(body, page)
    words = tokens(body)
    page_norm = norm(page)
    words.each_cons(8).count { |window| page_norm.include?(window.join(" ")) }
  end

  def contains_text?(fragment, evidence)
    needle = norm(evidence)
    return false if needle.blank? || tokens(needle).size < 4

    norm(fragment).include?(needle)
  end

  def same_text?(left, right)
    shorter, longer = [ tokens(left), tokens(right) ].sort_by(&:size)
    return false if shorter.size < 8

    shorter.count { |word| longer.include?(word) }.to_f / shorter.size >= 0.9
  end

  def parser
    @parser ||= BatchResultsParserService.new(s3_service: :local)
  end

  def flatten(text)
    text.to_s.gsub(/\s+/, " ").strip
  end

  def tokens(text)
    norm(text).split
  end

  def norm(text)
    I18n.transliterate(utf8(text)).downcase.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
  end

  def utf8(text)
    value = text.to_s.dup
    value.force_encoding(Encoding::UTF_8)
    value.valid_encoding? ? value : value.scrub
  end
end
