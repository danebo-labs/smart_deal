# frozen_string_literal: true

module Rag
  # Versioned question and answer contract stored on the existing episode.
  # Ruby assigns local ids when a question is published. A reply points at the
  # history message and, when it names a slice, at character offsets Ruby has
  # checked. The reply does not replace the turn with a label or a paraphrase.
  # Episodes without qc stay on the previous reading.
  module AnswerContract
    VERSION = 1
    STATES = %w[complete partial unknown contradictory].freeze
    ROLES = %w[main clarification].freeze
    SETTLED = %w[complete unknown].freeze
    ID_LIMIT = 10_000

    module_function

    def stamp!(episode)
      question = episode.pending_question
      return unless question.is_a?(Hash) && question["type"] == "documented_context"
      return if question["question"].blank?

      episode.qc = VERSION
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

    # Proposals that do not belong to this episode are ignored. A rejected
    # proposal does not close a part and does not allocate a reply id.
    def apply!(episode, turn:, correlation_id:, proposals:)
      admitted = admitted_text(turn)
      Array(proposals).each do |raw|
        store_one!(episode, admitted, correlation_id, raw)
      end
      episode
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
      return [] unless episode.respond_to?(:replies) && episode.qc == VERSION

      Array(episode.replies).map { |reply|
        text = reconstruct(reply, session)
        label = "#{reply['q']}.#{reply['p']} #{reply['state']}"
        cut = cut_note(session, reply)
        if text.nil?
          "Respuesta #{reply['id']} a #{label}: el texto no se reconstruyó desde el historial.#{cut}"
        else
          "Respuesta #{reply['id']} a #{label}: «#{text}».#{cut}"
        end
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
      return false unless raw.is_a?(Hash)

      question = episode.pending_question
      return false unless question.is_a?(Hash)

      qid = raw["question_id"].to_s
      pid = raw["part_id"].to_s
      state = raw["state"].to_s
      return false unless qid == question["id"].to_s && qid.match?(/\Aq\d+\z/)

      part = Array(question["parts"]).find { |item| item.is_a?(Hash) && item["id"] == pid }
      return false unless part && STATES.include?(state)

      span = span_for(admitted, raw)
      return false if span.nil?

      referenced = supersedes_ids(raw)
      return false if referenced == :invalid
      return false unless allow_reply?(episode, pid, state, referenced)

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
      return false unless fits?(episode, reply, seq)

      episode.qc = VERSION
      episode.id_seq = seq
      episode.replies = Array(episode.replies) + [ reply ]
      true
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

    def allow_reply?(episode, part_id, state, ids)
      current = current_replies(episode, part_id)
      return false if ids.any? && ids.any? { |id| current.none? { |reply| reply["id"] == id } }

      state_now = state_of(current)
      if state_now == "contradictory" && state != "contradictory"
        conflicting = current.select { |reply| reply["state"] == "contradictory" }.pluck("id")
        return false if (conflicting - ids).any?
      end
      return false if SETTLED.include?(state_now) && ids.empty? && state != "contradictory"

      true
    end

    def state_of(current)
      return nil if current.empty?
      return "contradictory" if current.any? { |reply| reply["state"] == "contradictory" }

      current.last["state"]
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
    private_class_method :store_one!, :span_for, :supersedes_ids, :allow_reply?, :state_of, :fits?, :cut_note, :allocate_id!
  end
end
