# frozen_string_literal: true

module Rag
  # Versioned question and answer contract stored on the existing episode.
  # The version is chosen once, when the episode is opened, and then stays
  # fixed. Publishing a question does not select it. On the new contract,
  # Ruby assigns local ids when a question is published. A reply points at
  # the history message and, when it names a slice, at character offsets Ruby
  # has checked. The reply does not replace the turn with a label or a
  # paraphrase. Episodes without qc stay on the previous reading.
  module AnswerContract
    VERSION = 1
    STATES = %w[complete partial unknown contradictory].freeze
    ROLES = %w[main clarification declared].freeze
    DECLARED_LIMIT = 2
    SETTLED = %w[complete unknown].freeze
    ID_LIMIT = 10_000

    module_function

    # Ids and parts belong to an episode already selected as the new contract.
    # This does not write qc. A legacy episode stays legacy.
    def stamp!(episode)
      return unless active?(episode)

      question = episode.pending_question
      return unless question.is_a?(Hash) && question["type"] == "documented_context"
      return if question["question"].blank?

      question["id"] = question["id"].presence || allocate_id!(episode, "q", "q")
      return if question["id"].blank?

      parts = Array(question["parts"]).select { |part| part.is_a?(Hash) }
      unless parts.any? { |part| part["role"] == "main" && part["id"].present? && part["text"].present? }
        part_id = allocate_id!(episode, "p", "p")
        return if part_id.blank?

        parts << { "id" => part_id, "role" => "main", "text" => question["question"].to_s }
      end
      shown = question["shown"]
      if shown.is_a?(Hash) && shown["question"].present? &&
          parts.none? { |part| part["role"] == "clarification" && part["id"].present? && part["text"].present? }
        part_id = allocate_id!(episode, "p", "p")
        if part_id.present?
          parts << { "id" => part_id, "role" => "clarification", "text" => shown["question"].to_s }
        end
      end
      question["parts"] = parts
      episode.pending_question = question
    end

    def keep_open_formulation?(question, plan)
      ref = plan.is_a?(Hash) ? plan["question_ref"].to_s : ""
      ref.match?(/\Aq\d+\z/) && question.is_a?(Hash) && question["id"].to_s == ref
    end

    def payload_questions(episode)
      question = episode.pending_question
      return nil unless question.is_a?(Hash) && question["id"].present?

      parts = open_parts(episode).map { |part|
        { "id" => part["id"], "role" => part["role"], "text" => part["text"] }
      }
      return nil if parts.empty?

      [ { "id" => question["id"], "parts" => parts } ]
    end

    def open_parts(episode)
      question = episode.pending_question
      return [] unless question.is_a?(Hash)

      Array(question["parts"]).select { |part| open_part?(episode, question, part) }
    end

    def open_part?(episode, question, part)
      return false unless part.is_a?(Hash)
      return false if SETTLED.include?(part_state(episode, part["id"]))

      text = part["text"].to_s
      return false if text.blank?

      text == question["question"].to_s || text == question.dig("shown", "question").to_s
    end

    def part_state(episode, part_id)
      state_of(current_replies(episode, part_id))
    end

    def settled?(state)
      SETTLED.include?(state)
    end

    def current_replies(episode, part_id)
      rows = Array(episode.replies).select { |reply| reply["p"] == part_id.to_s }
      covered = rows.flat_map { |reply| Array(reply["of"]) }
      rows.reject { |reply| covered.include?(reply["id"]) }
    end

    def active?(episode)
      episode.respond_to?(:qc) && episode.qc == VERSION
    end

    # The only writer of qc. ActiveEpisode.open calls this on a new episode,
    # before that episode is interpreted. The product default is VERSION.
    # nil and any other value leave the legacy reading, for an episode opened
    # that way on purpose. Publishing a question does not call this. A stored
    # episode without qc stays on the legacy reading.
    def select!(episode, requested)
      episode.qc = requested == VERSION ? VERSION : nil
      episode
    end

    def label(episode)
      active?(episode) ? "contract" : "legacy"
    end

    # contract is the version selected when this episode was opened.
    # Publishing a question does not change it. field is absent, empty,
    # invalid, or present. None of those values invents an association.
    def apply!(episode, turn:, correlation_id:, proposals:, contract:, field:)
      report = {
        "route" => contract ? "contract" : "legacy",
        "field" => field.to_s,
        "stored" => [],
        "refused" => []
      }
      unless contract
        Array(proposals).each { |raw| report["refused"] << refusal(raw, "not_contract") }
        return report
      end

      admitted = admitted_text(turn)
      Array(proposals).each do |raw|
        reason = store_one!(episode, admitted, correlation_id, raw)
        if reason
          report["refused"] << refusal(raw, reason)
        else
          report["stored"] << episode.replies.last["id"]
        end
      end
      report
    end

    def reconstruct(reply, session)
      return nil unless reply.is_a?(Hash)

      message = SessionContextBuilder.companion_message_for(session, reply["cid"])
      return nil unless message.is_a?(Hash)

      body = SessionContextBuilder.companion_message_text(message)
      return body unless reply.key?("a") || reply.key?("b")

      start = reply["a"]
      finish = reply["b"]
      return nil unless start.is_a?(Integer) && finish.is_a?(Integer)
      return nil unless start >= 0 && finish >= start && finish <= body.length

      body[start...finish]
    end

    def context_lines(episode, session)
      return [] unless active?(episode)

      lines = Array(episode.replies).map { |reply|
        text = reconstruct(reply, session)
        cut = cut_note(session, reply)
        if text.nil?
          "Respuesta #{reply['id']} a #{reply['q']}.#{reply['p']}: el texto no se reconstruyó desde el historial. El estado almacenado no se usa como respuesta reconstruida.#{cut}"
        else
          "Respuesta #{reply['id']} a #{reply['q']}.#{reply['p']} #{reply['state']}: «#{text}».#{cut}"
        end
      }
      lines + conflict_lines(episode)
    end

    # Settled parts stay out of the open question. The ids let a later turn
    # name the reply it replaces. A missing source does not carry the state
    # as if the text had been reconstructed.
    def correction_refs(episode, session = nil)
      return [] unless active?(episode)

      question = episode.pending_question
      return [] unless question.is_a?(Hash)

      qid = question["id"].to_s
      Array(question["parts"]).flat_map { |part|
        next [] unless part.is_a?(Hash)
        next [] if open_part?(episode, question, part)

        current_replies(episode, part["id"]).map { |reply|
          text = session ? reconstruct(reply, session) : nil
          row = { "id" => reply["id"], "question_id" => qid, "part_id" => part["id"] }
          if text.nil?
            row["text_available"] = false
          else
            row["text"] = text
            row["state"] = reply["state"]
          end
          row
        }
      }
    end

    def conflict_refs(episode)
      return [] unless active?(episode)

      question = episode.pending_question
      return [] unless question.is_a?(Hash)

      Array(question["parts"]).filter_map { |part|
        next unless part.is_a?(Hash)
        next unless part_state(episode, part["id"]) == "contradictory"

        ids = current_replies(episode, part["id"]).pluck("id")
        next if ids.size < 2

        { "question_id" => question["id"], "part_id" => part["id"], "reply_ids" => ids }
      }
    end

    def admitted_text(turn)
      text = turn.to_s
      cap = ConversationSession::USER_TEXT_MAX_CHARS
      text.length <= cap ? text : text[0, cap]
    end

    def allocate_id!(episode, key, prefix)
      seq = (episode.id_seq || { "q" => 0, "p" => 0, "r" => 0 }).dup
      number = seq[key].to_i + 1
      return nil if number >= ID_LIMIT

      seq[key] = number
      episode.id_seq = seq
      "#{prefix}#{number}"
    end

    def store_one!(episode, admitted, correlation_id, raw)
      return "not_a_reply" unless raw.is_a?(Hash)

      question = episode.pending_question
      return "unknown_question" unless question.is_a?(Hash)

      qid = raw["question_id"].to_s
      state = raw["state"].to_s
      return "unknown_question" unless qid == question["id"].to_s && qid.match?(/\Aq\d+\z/)
      return store_declared!(episode, admitted, correlation_id, raw, question) if raw["part_id"].nil?

      pid = raw["part_id"].to_s
      return "invalid_state" unless STATES.include?(state)

      part = Array(question["parts"]).find { |item| item.is_a?(Hash) && item["id"] == pid }
      return "unknown_part" unless part

      span = span_for(admitted, raw)
      return "invalid_span" if span.nil?

      referenced = supersedes_ids(raw)
      blocked = reply_block(episode, pid, state, referenced)
      return blocked if blocked

      seq = episode.id_seq.dup
      seq["r"] = seq["r"].to_i + 1
      reply = {
        "id" => "r#{seq['r']}",
        "q" => qid,
        "p" => pid,
        "state" => state,
        "cid" => correlation_id.to_s
      }
      if span[:ranged]
        reply["a"] = span[:a]
        reply["b"] = span[:b]
      end
      reply["of"] = referenced if referenced.any?
      targets = reply_targets(question, part, state)
      reply["t"] = targets if targets
      return "budget" unless fits?(episode, reply, seq)

      episode.id_seq = seq
      episode.replies = Array(episode.replies) + [ reply ]
      nil
    end

    # A clause the technician added, not an answer to a published part. The
    # part text is that slice. It carries no documentary target. Two is the
    # maximum kept on the current question. A span that meets another
    # declared span is refused. The byte budget is the episode budget.
    def store_declared!(episode, admitted, correlation_id, raw, question)
      return "invalid_state" unless raw["state"].to_s == "unknown"

      span = span_for(admitted, raw)
      return "invalid_span" unless span && span[:ranged]

      parts = Array(question["parts"]).select { |item| item.is_a?(Hash) }
      declared = parts.select { |part| part["role"] == "declared" }
      return "declared_limit" if declared.size >= DECLARED_LIMIT

      fragment = admitted[span[:a]...span[:b]]
      return "overlap" if declared.any? { |part|
        range = current_span(episode, part["id"])
        range && spans_overlap?(span[:a], span[:b], range[0], range[1])
      }

      referenced = supersedes_ids(raw)
      previous_seq = (episode.id_seq || { "q" => 0, "p" => 0, "r" => 0 }).dup
      previous_parts = parts.map(&:dup)
      part_id = allocate_id!(episode, "p", "p")
      return restore_declared(episode, question, previous_seq, previous_parts, "id_limit") if part_id.blank?

      question["parts"] = parts + [ { "id" => part_id, "role" => "declared", "text" => fragment } ]
      episode.pending_question = question
      blocked = reply_block(episode, part_id, "unknown", referenced)
      return restore_declared(episode, question, previous_seq, previous_parts, blocked) if blocked

      seq = episode.id_seq.dup
      seq["r"] = seq["r"].to_i + 1
      reply = {
        "id" => "r#{seq['r']}",
        "q" => question["id"].to_s,
        "p" => part_id,
        "state" => "unknown",
        "cid" => correlation_id.to_s,
        "a" => span[:a],
        "b" => span[:b]
      }
      reply["of"] = referenced if referenced.is_a?(Array) && referenced.any?
      unless fits?(episode, reply, seq)
        return restore_declared(episode, question, previous_seq, previous_parts, "budget")
      end

      episode.id_seq = seq
      episode.replies = Array(episode.replies) + [ reply ]
      nil
    end

    def current_span(episode, part_id)
      reply = current_replies(episode, part_id).reverse.find { |row|
        row["a"].is_a?(Integer) && row["b"].is_a?(Integer)
      }
      reply && [ reply["a"], reply["b"] ]
    end

    def spans_overlap?(left, left_end, right, right_end)
      left < right_end && right < left_end
    end

    def restore_declared(episode, question, seq, parts, reason)
      episode.id_seq = seq
      question["parts"] = parts
      episode.pending_question = question
      reason
    end

    def span_for(admitted, raw)
      start = raw.key?("start") ? raw["start"] : nil
      finish = raw.key?("end") ? raw["end"] : nil
      return { ranged: false } if start.nil? && finish.nil?
      return nil unless start.is_a?(Integer) && finish.is_a?(Integer)
      return nil if start < 0 || finish < start || finish > admitted.length
      return nil if admitted[start...finish].blank?

      { ranged: true, a: start, b: finish }
    end

    def supersedes_ids(raw)
      value = raw["supersedes"]
      return [] if value.nil?

      ids = value.is_a?(Array) ? value : [ value ]
      return :invalid unless ids.all? { |id| id.is_a?(String) && id.match?(/\Ar\d+\z/) }

      ids
    end

    def reply_block(episode, part_id, state, ids)
      return "invalid_supersedes" if ids == :invalid

      current = current_replies(episode, part_id)
      return "invalid_supersedes" if ids.any? && ids.any? { |id| current.none? { |reply| reply["id"] == id } }

      state_now = state_of(current)
      if state_now == "contradictory" && state != "contradictory"
        conflicting = current.select { |reply| reply["state"] == "contradictory" }.pluck("id")
        return "invalid_supersedes" if (conflicting - ids).any?
      end
      return "settled" if SETTLED.include?(state_now) && ids.empty? && state != "contradictory"

      nil
    end

    def refusal(raw, reason)
      row = { "reason" => reason }
      row["part_id"] = raw["part_id"].to_s if raw.is_a?(Hash) && raw["part_id"].present?
      row
    end

    def conflict_lines(episode)
      conflict_refs(episode).map { |conflict|
        ids = conflict["reply_ids"].join(", ")
        "#{conflict['question_id']}.#{conflict['part_id']} en conflicto: hay versiones vigentes (#{ids}). Ninguna queda elegida como hecho resuelto."
      }
    end

    def state_of(current)
      return nil if current.empty?
      return "contradictory" if current.any? { |reply| reply["state"] == "contradictory" }

      current.last["state"]
    end

    # The documented item the unknown reply could not identify. It belongs to
    # the part's own question, so a later clarification does not replace it.
    def reply_targets(question, part, state)
      return nil unless state == "unknown"

      source = if part["text"].to_s == question["question"].to_s
        question["targets"]
      elsif question["shown"].is_a?(Hash) && part["text"].to_s == question.dig("shown", "question").to_s
        question.dig("shown", "targets")
      end
      targets = Array(source).filter_map { |item| PendingQuestion.documented_target(item) }.first(2)
      targets.presence
    end

    def fits?(episode, reply, seq)
      payload = episode.serial_hash
      payload["qc"] = VERSION
      payload["id_seq"] = seq
      payload["replies"] = Array(episode.replies) + [ reply ]
      payload.compact!
      JSON.generate(payload).bytesize <= ActiveEpisode::MAX_BYTES
    end

    def cut_note(session, reply)
      message = SessionContextBuilder.companion_message_for(session, reply["cid"])
      return "" unless message.is_a?(Hash) && SessionContextBuilder.companion_message_cut?(message)

      " Texto almacenado truncado en el historial, no es el mensaje íntegro."
    end
    private_class_method :store_one!, :store_declared!, :current_span, :spans_overlap?,
      :restore_declared, :span_for, :supersedes_ids, :reply_block, :refusal,
      :conflict_lines, :state_of, :reply_targets, :fits?, :cut_note, :allocate_id!
  end
end
