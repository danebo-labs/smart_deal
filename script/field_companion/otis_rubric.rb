# frozen_string_literal: true

# Acceptance rubric for case 29 (Otis, 0102) turns T5 and T6, as written in
# docs/field_companion/DANEBO_GUIONES_REGRESION_2026-11-19.md. It reads the
# state after reload, the citations the publication delivered and the
# published text. It does not compare against a fixed phrase or a fixed
# citation number: a passage is judged by the document it comes from and by
# what it says, and a statement by what it means (equivalent wordings
# accepted).
#
# Pure: no database, no network. Each check returns true or false and the
# verdict lists the failed ones by name.
module Stage1Live
  module OtisRubric
    module_function

    # What the manual's DFC line says, however the number or page differs.
    DFC_MEANING = /puertas\s+completamente\s+cerradas|cadena\s+de\s+seguridad\s+cerrada/i
    DCL = /\bDCL\b/i
    DFC = /\bDFC\b/i
    # The removed obstruction, however it is worded: the residue itself, the
    # cleaning or the removal.
    RESIDUE = /residuo|suciedad|obstrucci[oó]n|obstruid|impedimento|gu[ií]a|limpie|limpi[oó]|retir/i
    # The model's own reading, worded as likely and not as established.
    LIKELY = /m[aá]s\s+probable|probablemente|probable|plausible|lo\s+m[aá]s\s+razonable|coherente\s+con|consistente\s+con|explicar[ií]a|apunta\s+a|compatible\s+con/i
    # What the answer asserts about the test: the door closed completely and
    # the fault did not come back.
    RESULT = /cerr[oó]\s+por\s+completo|cierre\s+completo|complet[oó]\s+el\s+cierre|sin\s+reaparecer|no\s+(?:volvi[oó]|reapareci[oó]|apareci[oó])\b/i
    # The assertion is tied to that maneuver.
    SCOPE = /\b(?:en|durante)\s+(?:tu|esa|esta|la|una)\s+(?:prueba|maniobra)\b|\b(?:se\s+)?(?:limita|acota|restringe)\w*\s+a\s+(?:tu|la|esa|esta|una)\s+(?:prueba|maniobra)\b|\b(?:esa|esta|una)\s+(?:prueba|maniobra)\b|\b(?:solo\s+)?(?:vale|aplica)\s+(?:solo\s+)?para/i
    # The sentence that binds the result to the test, not just names it.
    SCOPE_STATEMENT = /alcance|resultado|\bvale\b|\baplica\b|solo|[uú]nicamente|\blimita\w*|\bacota\w*/i
    SUGGESTION = /observ|revis|verific|mir[ae]|comprueb|vigil|pendiente\s+de|atent|conviene|podr[ií]as|otra\s+maniobra|pr[oó]xima\s+maniobra/i
    UNVERIFIED_STATEMENT = /sin\s+verific|no\s+(?:se\s+)?(?:ha\s+)?verific|no\s+(?:llegamos|pudimos)\s+a\s+verific|sigue\s+sin|queda\s+sin/i
    CLOSED_AS_FIXED = /\b(?:queda|qued[oó]|est[aá])\s+(?:resuelt|solucionad|reparad)|certifica\s+la\s+puesta/i
    UNVERIFIED = %w[not_done unknown].freeze

    # --- T1 to T4 -----------------------------------------------------
    # The "Al recargar" lines of the regression document, read from the
    # state the real turns left. Nothing here compares a fixed sentence.

    ZERO_102 = /\b0102\b/
    DOOR_REOPENS = /abr/i
    # What the technician can read off the equipment: the event history, a
    # code, a message or the console display.
    EVENT_MEANING = /0102.{0,80}(?:no\s+(?:fue\s+capaz\s+de\s+)?cerrar|no\s+cierra)|(?:no\s+(?:fue\s+capaz\s+de\s+)?cerrar|no\s+cierra).{0,40}(?:DCL|tiempo)/im
    EVENT_REQUEST = /evento|historial|c[oó]digo|consola|pantalla|display|registro\s+de\s+(?:falla|error|evento)|mensaje\s+de\s+(?:error|falla|diagn[oó]stico)/i
    # The leaf, the guide and what blocks the door: what the T3 photo and the
    # technician's story put on the table.
    DOOR_PATH = /hoja|cierre|detiene|llega|trab|completo|roz|residuo|obstru|gu[ií]a|umbral|pat[ií]n/i
    # A sentence that says a signal is missing or the cause.
    LOSS_OR_CAUSE = /perd|falt|desaparec|ausen|caus|porque|se\s+debe/i
    HEDGED = /\b(?:alguna|cualquiera|cu[aá]l|qu[eé]\s+se[nñ]al|hip[oó]tesis|no\s+se\s+sabe|sin\s+verificar|no\s+verific|pendiente)/i
    SIGNALS = %w[DCL DFC DW].freeze
    # The wording that keeps a cited table tied to what the case has not
    # confirmed: the plate, the controller, the installation.
    APPLICABILITY_LIMIT = /no\s+(?:confirma|identifica|establece)\s+(?:la\s+placa|el\s+equipo|el\s+controlador|la\s+instalaci[oó]n|la\s+configuraci[oó]n|esta\s+instalaci[oó]n)|referencia\s+(?:es\s+)?condicional|referencia\s+condicional|(?:placa|controlador)\s+(?:sin|no)\s+confirmar/i

    # T1 asks for the history event, or for something else the equipment shows
    # (a code, a message, the console) that routes the next turn. A question
    # about a variant of the manual (front or rear door) is not that: its
    # answer does not bring the case closer to a verified event, and in run
    # 20261120T121417Z the technician never answered it in T2 or T3.
    def t1(summary, allowed_documents:)
      verdict(
        "history_event_or_equivalent_requested" => asks?(summary, EVENT_REQUEST),
        "identifier_kept_as_typed" => Array(summary["identifiers"]).any? { |row| row["value"].to_s.match?(/\AGECGB\z/i) },
        "reopening_recorded_as_report" => Array(summary["all_observations"]).any? { |text| text.to_s.match?(/puerta/i) && text.to_s.match?(DOOR_REOPENS) },
        "console_labels_kept_from_photo" => labels_kept?(summary, %w[COR CR]),
        "no_0102_yet" => Array(summary["all_observations"]).none? { |text| text.to_s.match?(ZERO_102) },
        "photo_is_the_active_observation" => summary["photo"].to_s == "loaded" || !summary["photo"].to_s.empty?,
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents)
      )
    end

    # T2 explains the event the technician read. The pinned manuals say what
    # 0102 means, and that the door did not close in the allowed time because
    # one of DCL, DFC or DW is lost; they do not say which one to check first
    # on this controller. So the rubric asks for a faithful, cited explanation
    # and that no single signal is named as the lost one. It does not demand
    # DCL (or any other check) as the first step.
    def t2(summary, allowed_documents:)
      verdict(
        "event_recorded_as_history_report" => Array(summary["all_observations"]).any? { |text| text.to_s.match?(ZERO_102) },
        "event_backed_by_a_passage" => cited_citations(summary).compact.any? { |c| source_says?(summary, c, EVENT_MEANING) },
        "no_single_signal_named_as_lost" => !signal_assumed?(summary),
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents)
      )
    end

    # T3 moves forward from the photo (the degraded guide) and the technician's
    # story. The question that was open before the turn and went unanswered is
    # not asked again as if nothing had been said.
    def t3(summary, allowed_documents:)
      verdict(
        "dcl_still_unverified_on_record" => Array(summary["all_observations"]).any? { |text| text.to_s.match?(DCL) } || unverified?(summary, DCL),
        "two_photos_in_order" => Array(summary["photo_turns"]).pluck("sequence") == [ 1, 3 ],
        "guide_photo_active" => summary["photo"].to_s == "loaded",
        "advances_from_photo_and_report" => !repeats_open_question?(summary) && asks?(summary, DOOR_PATH),
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents)
      )
    end

    # The event and the DCL declaration of the earlier turns are kept: as
    # observations or, for DCL, as the check the technician declared.
    def t4(summary, allowed_documents:)
      earlier = Array(summary["earlier_observations"])
      earlier_checks = rows(summary["earlier_checks"])
      verdict(
        "stop_before_closing_recorded" => Array(summary["observations"]).any? { |text| text.to_s.match?(/detiene|antes/i) },
        "event_and_dcl_kept" => earlier.any? { |text| text.to_s.match?(ZERO_102) } &&
          (earlier.any? { |text| text.to_s.match?(DCL) } || earlier_checks.any? { |row| row["subject"].to_s.match?(DCL) }),
        "mechanical_impediment_asked" => summary["asked_again"].to_s.match?(/trab|roz|impedim|obstru|punto|residuo|umbral/i),
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents)
      )
    end

    def labels_kept?(summary, labels)
      text = Array(summary["visible_text"]).join(" ")
      labels.all? { |label| text.match?(/\b#{label}\b/) }
    end

    def passage_says?(citation, pattern)
      citation["tooltip_excerpt"].to_s.match?(pattern) || citation["excerpt"].to_s.match?(pattern)
    end

    # The tooltip excerpt exists only when the answer quotes the passage.
    # A paraphrase cited as [1][2] is backed all the same when the source the
    # generator received under that number holds the row (live 20261120T141251Z
    # T2: p. 22 and p. 85 carry the 0102 row, the answer did not quote it).
    def source_says?(summary, citation, pattern)
      return true if passage_says?(citation, pattern)

      summary.fetch("generator_sources", {}).to_h.transform_keys(&:to_s)[citation["number"].to_s].to_s.match?(pattern)
    end

    def t5(summary, allowed_documents:)
      verdict(
        "previous_check_addressed" => previous_check_addressed?(summary),
        "dcl_and_dfc_kept_unverified" => unverified?(summary, DCL) && unverified?(summary, DFC),
        "dcl_not_asked" => !asks?(summary, DCL),
        "question_not_repeated" => !summary["repeats_open_question"],
        "result_limited_to_the_test" => limited?(summary),
        "residue_named_as_likely_explanation" => residue_likely?(summary),
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents),
        "dfc_suggestion_backed_when_made" => dfc_suggestion_backed?(summary),
        "dfc_table_limited_to_the_case_controller" => dfc_table_limited?(summary),
        "pending_keeps_its_source" => pending_keeps_source?(summary, allowed_documents)
      )
    end

    def t6(summary, allowed_documents:)
      opened = summary["opened_pending"]
      verdict(
        "maneuver_result_recorded" => observed?(summary, DFC) && observed?(summary, /cerr|cierre/i),
        "dfc_thread_kept" => thread_kept?(summary, opened),
        "published_question_is_the_pending" => published_question_is_pending?(summary),
        "dcl_kept_unverified" => dcl_kept_unverified?(summary),
        "dcl_never_marked_done" => dcl_rows(summary).none? { |row| row["status"].to_s == "done" },
        "dcl_not_asked_again" => !asks?(summary, DCL) && !questions(summary["published"]).any? { |text| text.match?(DCL) },
        "no_new_dfc_question" => !asks?(summary, DFC),
        "state_survives_reload" => state_survives?(summary),
        "dfc_table_limited_to_the_case_controller" => dfc_table_limited?(summary),
        "citations_from_the_loaded_manuals" => citations_from?(summary, allowed_documents)
      )
    end

    def verdict(checks)
      failed = checks.reject { |_name, passed| passed }.keys
      { "ok" => failed.empty?, "failed" => failed, "checks" => checks }
    end

    # --- T5 -----------------------------------------------------------

    def unverified?(summary, pattern)
      rows(summary["checks"]).any? { |row| UNVERIFIED.include?(row["status"].to_s) && row["subject"].to_s.match?(pattern) }
    end

    def asks?(summary, pattern)
      summary["asked_again"].to_s.match?(pattern)
    end

    # What the answer asserts about the test (the door closed completely, the
    # fault did not come back) is tied to that maneuver, in the sentence or in
    # a declarative sentence of its paragraph. A mention in the question does
    # not count. No sentence declares the case fixed or certified: "no
    # confirma ... ni certifica la puesta" is a denial.
    # The scope may sit in the sentence, in its paragraph, or in a paragraph of
    # its own that says the result is valid for one test («Alcance: el
    # resultado vale para una prueba…»). A model that separates the result from
    # its scope is not asserting more than the test.
    def limited?(summary)
      blocks = blocks(summary["published"])
      asserted = blocks.flat_map { |block| declarative(block).select { |sentence| sentence.match?(RESULT) }.map { |sentence| [ sentence, block ] } }
      return false if asserted.empty?

      scope_statement = blocks.flat_map { |block| declarative(block) }.any? { |sentence| sentence.match?(SCOPE) && sentence.match?(SCOPE_STATEMENT) }
      scoped = asserted.all? do |sentence, block|
        sentence.match?(SCOPE) || declarative(block).any? { |other| other.match?(SCOPE) } || scope_statement
      end
      scoped && sentences(summary["published"]).none? { |sentence| sentence.match?(CLOSED_AS_FIXED) && !sentence.match?(/\b(?:no|ni|sin)\b/i) }
    end

    # A table of the manual cited for what DFC means keeps the limit of what
    # the case has not confirmed (the plate, the controller). Nothing cited,
    # nothing to limit.
    def dfc_table_limited?(summary)
      table_cited = cited_citations(summary).compact.any? { |citation| passage_says?(citation, DFC_MEANING) }
      !table_cited || summary["published"].to_s.match?(APPLICABILITY_LIMIT)
    end

    # No single signal is named as the lost one when the source lists three.
    def signal_assumed?(summary)
      sentences(summary["published"]).any? do |sentence|
        next false if sentence.include?("?") || sentence.match?(HEDGED) || !sentence.match?(LOSS_OR_CAUSE)

        SIGNALS.count { |signal| sentence.match?(/\b#{signal}\b/) } == 1
      end
    end

    def repeats_open_question?(summary)
      before = summary["pending_before"]
      asked = summary["asked_again"].to_s
      before.is_a?(Hash) && asked.present? && normalized(asked) == normalized(before["question"])
    end

    def normalized(text)
      text.to_s.downcase.gsub(/[¿?¡!.,:;*]/, " ").squish
    end

    # A question the published text shows is the question that waits after the
    # reload, and a pending that waits was shown. Nothing shown and lost,
    # nothing waiting that nobody saw.
    def published_question_is_pending?(summary)
      pending = summary["pending"]
      shown = questions(summary["published"]).map { |text| normalized(text) }
      return shown.empty? if pending.nil?

      # The stored question may keep the clause in front of «¿» («con la
      # puerta cerrada, ¿el LED…?»). The publication shows that same «¿…?».
      span = pending["question"].to_s[/(¿[^?]*\?)/]
      asked = normalized(span || pending["question"])
      shown.any? { |text| text == asked }
    end

    # The check that was open before the turn is not left waiting. Its part is
    # answered (in part, in full, or as something the technician cannot give),
    # or the technician moved the case on and nothing waits on that question.
    # Read from the state the case really had: no part id is assumed.
    def previous_check_addressed?(summary)
      before = summary["pending_before"]
      return true unless before.is_a?(Hash) && !before.empty?

      ids = Array(before["parts"]).select { |part| part.is_a?(Hash) && part["role"] != "declared" }.pluck("id")
      return true if ids.any? { |id| %w[partial complete unknown].include?(summary.dig("part_states", id)) }

      pending = summary["pending"]
      (pending.nil? || pending["id"] != before["id"]) && Array(summary["observations"]).any?
    end

    # A sentence that names the removed obstruction and words it as likely,
    # without calling it the confirmed cause.
    def residue_likely?(summary)
      sentences(summary["published"]).any? do |sentence|
        sentence.match?(RESIDUE) && sentence.match?(LIKELY) &&
          (!sentence.match?(/causa\s+(?:confirmada|establecida)/i) || sentence.match?(/\bno\b/i))
      end
    end

    def citations_from?(summary, allowed)
      cited = cited_citations(summary)
      return false if cited.any? { |citation| citation.nil? }

      cited.all? { |citation| allowed.any? { |name| citation["filename"].to_s.include?(name) || citation["title"].to_s.include?(name) } }
    end

    # The optional suggestion to watch DFC on another maneuver. A sentence that
    # only says DFC is still unverified is not one. A suggestion needs a
    # citation in its paragraph whose passage says what DFC means.
    def dfc_suggestion_backed?(summary)
      blocks(summary["published"]).all? do |block|
        suggests = sentences(block).any? { |sentence| sentence.match?(DFC) && sentence.match?(SUGGESTION) && !sentence.match?(UNVERIFIED_STATEMENT) }
        next true unless suggests

        cited = cited_numbers(block).filter_map { |number| Array(summary["citations"]).find { |citation| citation["number"].to_i == number } }
        cited.any? { |citation| passage_says?(citation, DFC_MEANING) }
      end
    end

    # A pending keeps the document of what backs its question: the citations
    # in the paragraph that asks it, or in the check paragraph right before.
    # With none, its targets are [] and nothing is invented. With some, each
    # target is one of those passages, by document, file and page.
    def pending_keeps_source?(summary, allowed)
      pending = summary["pending"]
      return true if pending.nil?

      targets = Array(pending["targets"])
      backing = backing_citations(summary, pending["question"])
      return targets.empty? if backing.empty?

      targets.any? && targets.all? { |target| target_matches?(target, backing, allowed) }
    end

    def backing_citations(summary, question)
      blocks = blocks(summary["published"])
      index = blocks.index { |block| block.include?(question.to_s) }
      return [] unless index

      numbers = cited_numbers(blocks[index])
      numbers = cited_numbers(blocks[index - 1]) if numbers.empty? && index.positive?
      numbers.filter_map { |number| Array(summary["citations"]).find { |citation| citation["number"].to_i == number } }
    end

    def target_matches?(target, citations, allowed)
      return false if target["document_key"].to_s.empty? || target["filename"].to_s.empty?
      return false unless allowed.any? { |name| target["document_key"].to_s.include?(name) }

      citations.any? do |citation|
        file = File.basename(citation.dig("location", "key").to_s)
        file == target["filename"].to_s && citation["page"].to_s.sub(/\.0+\z/, "") == target["page"].to_s
      end
    end

    # --- T6 -----------------------------------------------------------

    def observed?(summary, pattern)
      Array(summary["observations"]).any? { |text| text.to_s.match?(pattern) }
    end

    # The reading belongs to the earlier conversation: it answered the open
    # question when that one asked for DFC, and otherwise the DFC the
    # technician had declared unverified is still on record to be answered.
    def thread_kept?(summary, opened)
      part = opened.is_a?(Hash) ? Array(opened["parts"]).find { |item| item["role"] != "declared" && item["text"].to_s.match?(DFC) } : nil
      return summary.dig("part_states", part["id"]) == "complete" if part

      Array(summary["earlier_checks"]).any? { |row| row["subject"].to_s.match?(DFC) }
    end

    def dcl_rows(summary)
      rows(summary["checks"]).select { |row| row["subject"].to_s.match?(DCL) }
    end

    # DCL stays unverified on record, from this turn or an earlier one, and
    # was never marked done. The interpreter may not repeat a declaration that
    # is already stored: the state is what counts.
    def dcl_kept_unverified?(summary)
      rows = dcl_rows(summary)
      rows.any? { |row| UNVERIFIED.include?(row["status"].to_s) } && rows.none? { |row| row["status"].to_s == "done" }
    end

    # Earlier observations and checks are still there after the reload.
    def state_survives?(summary)
      earlier = Array(summary["earlier_observations"])
      kept = Array(summary["all_observations"])
      earlier.any? && earlier.all? { |text| kept.include?(text) } &&
        Array(summary["earlier_checks"]).all? { |row| rows(summary["checks"]).any? { |item| item["subject"] == row["subject"] } }
    end

    # --- helpers ------------------------------------------------------

    def rows(value)
      Array(value).select { |row| row.is_a?(Hash) }
    end

    def blocks(text)
      text.to_s.split(/\n{2,}/).map(&:strip).reject(&:empty?)
    end

    # The sentences of a paragraph that state something: no question.
    def declarative(block)
      sentences(block).reject { |sentence| sentence.include?("?") || sentence.include?("¿") || sentence.match?(/\A(?:\*\*)?pregunta\b/i) }
    end

    def sentences(text)
      text.to_s.split(/(?<=[.!?])\s+|\n+/).map(&:strip).reject(&:empty?)
    end

    def questions(text)
      text.to_s.scan(/¿[^?]*\?/)
    end

    def cited_numbers(text)
      text.to_s.scan(/\[(\d+)\]/).flatten.map(&:to_i).uniq
    end

    # nil for a cited number the publication did not deliver.
    def cited_citations(summary)
      list = Array(summary["citations"])
      cited_numbers(summary["published"]).map { |number| list.find { |citation| citation["number"].to_i == number } }
    end
  end
end
