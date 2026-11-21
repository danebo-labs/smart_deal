# frozen_string_literal: true

module Rag
  # What happened to the check Danebo had open, read once from the episode
  # AnswerContract stored. Nothing here decides a reply: the interpreter did
  # that and AnswerContract.apply! accepted or refused it. The episode and the
  # technician's correlation id are enough to rebuild this object, so a
  # request that only has the persisted state (a reload, a photo snapshot)
  # reads the same outcome.
  #
  # One object feeds the generator block, the trace, and the next-check note.
  # The text of a check that is no longer the pending one is rebuilt from the
  # history, as AnswerContract.reconstruct does for the technician's words.
  # The episode stores only the correlation of each reply.
  #
  # A reopened case can hold replies to turns older than the three the
  # session restores. The reference is then the reply's correlation id: it
  # names a completed FieldTurn of the same case, which holds the
  # technician's words, and the completed turn before it holds the question
  # Danebo published. When either is not there, the stored state is kept
  # without that text and missing_references says which one was absent.
  class CheckOutcome
    ACTIVE_PREFIX = "Comprobación activa"
    HEADING = "Estado de la comprobación:"
    MAX_CLOSED = 4
    MAX_UNVERIFIED = 6
    TEXT_CAP = 160
    GUIDE_OBSERVATION = "La foto de la guía es el dato nuevo. No pidas ejecutar ajustes mecánicos ni un procedimiento de un operador que no está confirmado. " \
      "La pregunta pide si la hoja llega al cierre o se detiene antes, o si algo en la guía la traba, roza u obstruye."

    Part = Data.define(:question_id, :part_id, :text, :state_before, :state, :settled_this_turn, :quote, :reply_id)
    Closed = Data.define(:question_id, :part_id, :state, :question, :quote, :correlation_id, :cut, :reply_id)
    Unverified = Data.define(:kind, :text, :correlation_id, :turn)

    attr_reader :correlation_id, :move, :perception_move, :active, :closed, :unverified, :open_parts,
                :missing_references

    # The outcome stored on the session this turn, else the one the episode
    # and the correlation give. Both are the same reading.
    def self.current(episode:, session:, correlation_id: nil)
      stored = session.check_outcome if session.respond_to?(:check_outcome)
      return stored if stored && (correlation_id.blank? || stored.correlation_id == correlation_id.to_s)

      new(episode: episode, session: session, correlation_id: correlation_id)
    end

    # Replaces AnswerContract.context_lines when FIELD_CHECK_OUTCOME is on.
    def self.context_lines(episode, session, correlation_id: nil)
      parsed = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      return AnswerContract.context_lines(parsed, session) unless CheckOutcomeFlag.enabled?

      current(episode: parsed, session: session, correlation_id: correlation_id).lines
    end

    # report is AnswerContract.apply!'s report. Without it the replies that
    # carry this turn's correlation id say the same thing.
    def initialize(episode:, session:, correlation_id:, perception_move: nil, report: nil)
      @episode = episode.is_a?(ActiveEpisode) ? episode : ActiveEpisode.parse(episode)
      @session = session
      @correlation_id = correlation_id.to_s
      @perception_move = perception_move.to_s.presence
      @report = report.is_a?(Hash) ? report : {}
      @active = []
      @closed = []
      @unverified = []
      @open_parts = []
      @missing_references = []
      compute if AnswerContract.active?(@episode)
      @move = derive_move
    end

    def settled_this_turn?
      active.any?(&:settled_this_turn)
    end

    def answered_this_turn?
      active.any?
    end

    # A check the technician answered only in part is still owed to the case.
    # It is open when this turn's reply left it partial, or when this turn
    # settled the active check and an earlier one was never completed. Once
    # the technician has declared something unverified, an old partial no
    # longer blocks the closing: the closing lists what is still unverified.
    def leaves_checks_open?
      return true if active.any? { |part| part.state == "partial" }

      settled_this_turn? && unverified.empty? && closed.any? { |row| row.state == "partial" }
    end

    def move_divergence?
      perception_move.present? && (perception_move == "answer_pending") != answered_this_turn?
    end

    def empty?
      active.empty? && closed.empty? && unverified.empty?
    end

    def to_trace
      {
        "correlation_id" => correlation_id,
        "move" => move,
        "perception_move" => perception_move,
        "move_divergence" => move_divergence?,
        "settled_this_turn" => settled_this_turn?,
        "active" => active.map { |part|
          { "question_id" => part.question_id, "part_id" => part.part_id, "state_before" => part.state_before,
            "state" => part.state, "settled_this_turn" => part.settled_this_turn, "reply_id" => part.reply_id }
        },
        "closed" => closed.map { |row|
          { "question_id" => row.question_id, "part_id" => row.part_id, "state" => row.state,
            "correlation_id" => row.correlation_id, "question_text" => row.question.present? }
        },
        "unverified" => unverified.map { |row|
          { "kind" => row.kind, "correlation_id" => row.correlation_id, "turn" => row.turn }
        },
        "open_parts" => open_parts,
        "missing_references" => missing_references,
        "stored" => Array(@report["stored"]),
        "refused" => Array(@report["refused"])
      }
    end

    # The block. Each line stands alone so the case budget can omit one whole.
    def lines
      return [] if @conflicts.blank? && empty?

      out = [ HEADING ]
      active.each { |part| out << active_line(part) }
      if closed.any?
        out << "Comprobaciones anteriores (el texto se reconstruye del historial):"
        closed.each { |row| out << closed_line(row) }
      end
      declared, undone_now = unverified.partition { |row| !undone_this_turn?(row) }
      if declared.any?
        out << "Declarado por el técnico como no verificado o inaccesible. No lo pidas de nuevo; si un turno posterior lo contesta, vale el posterior:"
        declared.each { |row| out << unverified_line(row) }
      end
      if undone_now.any?
        # Live 20261120T231049Z, Otis T3. The line told the model to ask the
        # next datum a source backs. The only such line was the PAX page
        # "Comprobar ajustes mecánicos", and that procedure became the
        # question. The photo of the guide is the new datum; the question
        # is what the leaf does there. A later turn that already reports
        # the residue or the correction does not get this sentence.
        notice = "Declarado en este turno como no hecho todavía. Es un reporte del técnico: no lo pidas como tu siguiente comprobación en " \
          "este turno. Parte de lo demás que trae el mismo mensaje (relato o foto) y pide solo otro dato que no figure arriba como " \
          "declarado antes, si una fuente de este turno lo respalda y la citas:"
        notice = "#{notice} #{GUIDE_OBSERVATION}" if guide_observation?(undone_now)
        out << notice
        undone_now.each { |row| out << unverified_line(row) }
      end
      out.concat(Array(@conflicts))
      out
    end

    private

    def compute
      question = @episode.pending_question.is_a?(Hash) ? @episode.pending_question : {}
      replies = Array(@episode.replies).select { |reply| reply.is_a?(Hash) }
      mine = @correlation_id.empty? ? [] : replies.select { |reply| reply["cid"] == @correlation_id }
      mine_ids = mine.pluck("id")
      @open_parts = AnswerContract.open_parts(@episode).pluck("id")
      @conflicts = AnswerContract.conflict_lines(@episode)

      mine.each do |reply|
        part = part_of(question, reply)
        next if part && part["role"] == "declared"

        pid = reply["p"].to_s
        before = AnswerContract.part_state_without(@episode, pid, mine_ids)
        state = AnswerContract.part_state(@episode, pid)
        @active << Part.new(
          question_id: reply["q"].to_s, part_id: pid, text: part&.dig("text") || history_question(reply),
          state_before: before, state: state,
          settled_this_turn: AnswerContract.settled?(state) && !AnswerContract.settled?(before),
          quote: quote_of(reply), reply_id: reply["id"].to_s
        )
      end

      covered = replies.flat_map { |reply| Array(reply["of"]) }
      closed = replies.reject { |reply| covered.include?(reply["id"]) || mine_ids.include?(reply["id"]) }.filter_map { |reply|
        part = part_of(question, reply)
        next if part && part["role"] == "declared"

        Closed.new(
          question_id: reply["q"].to_s, part_id: reply["p"].to_s, state: reply["state"].to_s,
          question: part&.dig("text") || history_question(reply),
          quote: reply["state"] == "unknown" ? nil : quote_of(reply),
          correlation_id: reply["cid"].to_s, cut: AnswerContract.cut_note(@session, reply),
          reply_id: reply["id"].to_s
        )
      }
      @closed = closed.last(MAX_CLOSED)
      @unverified = unverified_rows(replies, covered)
    end

    def part_of(question, reply)
      return nil unless question["id"].to_s == reply["q"].to_s

      Array(question["parts"]).find { |part| part.is_a?(Hash) && part["id"].to_s == reply["p"].to_s }
    end

    def quote_of(reply)
      text = AnswerContract.reconstruct(reply, @session)
      text = case_quote(reply) if text.nil? && SessionContextBuilder.companion_message_for(@session, reply["cid"]).nil?
      note_missing(reply, "technician_text") if text.nil?
      text&.squish&.first(TEXT_CAP)
    end

    # The assistant message just before the technician's reply is the one
    # that put the check in front of them.
    def history_question(reply)
      question = question_from_history(reply) || question_from_case(reply)
      note_missing(reply, "question_text") if question.nil?
      question
    end

    def question_from_history(reply)
      history = Array(@session.conversation_history) if @session.respond_to?(:conversation_history)
      return nil if history.blank?

      index = history.index { |message|
        message.is_a?(Hash) && message["role"] == "user" && message["correlation_id"].to_s == reply["cid"].to_s
      }
      return nil unless index

      prior = history[0...index].reverse.find { |message| message.is_a?(Hash) && message["role"] == "assistant" }
      return nil unless prior

      PendingQuestion.question_in(SessionContextBuilder.companion_message_text(prior))
    end

    def question_from_case(reply)
      reference = case_reference(reply)
      PendingQuestion.question_in(reference[:prior_published]) if reference && reference[:prior_published].present?
    end

    def case_quote(reply)
      reference = case_reference(reply)
      reference && AnswerContract.reply_slice(reply, reference[:message])
    end

    def case_reference(reply)
      return nil unless @session.respond_to?(:case_turn_reference)

      @session.case_turn_reference(reply["cid"])
    end

    def note_missing(reply, reference)
      entry = { "reply_id" => reply["id"].to_s, "correlation_id" => reply["cid"].to_s, "reference" => reference }
      @missing_references << entry unless @missing_references.include?(entry)
    end

    def unverified_rows(replies, covered)
      rows = []
      Array(@episode.checks).each do |item|
        next unless item.is_a?(Hash) && item["subject"].present? && item["status"].to_s != "done"

        span = SessionContextBuilder.companion_report_span(@session, item)
        text = (span[:kind] == :original ? span[:text] : item["subject"]).to_s.squish
        rows << Unverified.new(kind: "not_done", text: text.first(TEXT_CAP), correlation_id: item["correlation_id"].to_s,
                               turn: turn_of(item["correlation_id"]))
      end
      replies.each do |reply|
        next unless reply["state"] == "unknown" && covered.exclude?(reply["id"])

        text = quote_of(reply)
        next if text.blank?

        rows << Unverified.new(kind: "unknown", text: text, correlation_id: reply["cid"].to_s, turn: turn_of(reply["cid"]))
      end
      rows.uniq { |row| [ row.correlation_id, row.text.downcase ] }
        .sort_by { |row| [ row.turn || Float::INFINITY, row.correlation_id ] }
        .last(MAX_UNVERIFIED)
    end

    def turn_of(correlation_id)
      return nil if correlation_id.blank?

      @user_messages ||= SessionContextBuilder.companion_episode_user_messages(@session)
      index = @user_messages.index { |message| message["correlation_id"].to_s == correlation_id.to_s }
      index && index + 1
    end

    # The reducer's move can differ from what apply! stored. This keeps both,
    # so the trace shows where they diverge. Only a stored reply to an open
    # check makes the turn an answer.
    def derive_move
      return "answer_pending" if answered_this_turn?

      perception_move
    end

    def active_line(part)
      head = "#{ACTIVE_PREFIX} #{part.question_id}.#{part.part_id}"
      head += " «#{part.text}»" if part.text.present?
      words = part.quote.present? ? " «#{part.quote}»" : " (texto del técnico no reconstruido del historial)"
      case part.state
      when "complete"
        "#{head}: contestada en este turno (complete, #{part.reply_id}) con#{words}. No la repitas ni pidas de nuevo lo que ya cubre."
      when "unknown"
        "#{head}: el técnico no puede aportarla (unknown, #{part.reply_id}),#{words}. No la repitas."
      when "partial"
        "#{head}: respuesta parcial en este turno (#{part.reply_id}),#{words}. Falta completarla."
      when "contradictory"
        "#{head}: hay respuestas en conflicto (#{part.reply_id}),#{words}."
      else
        "#{head}: #{part.state}."
      end
    end

    def closed_line(row)
      head = "- #{row.question_id}.#{row.part_id}"
      head += " «#{row.question}»" if row.question.present?
      words = row.quote.present? ? " («#{row.quote}»)" : ""
      "#{head}: #{row.state} (#{row.reply_id})#{words}.#{row.cut}"
    end

    # A check the technician said this turn they did not get to. What they
    # cannot provide (unknown) and what an earlier turn left undone stay
    # under "no lo pidas de nuevo": they were already given the chance.
    def undone_this_turn?(row)
      row.kind == "not_done" && @correlation_id.present? && row.correlation_id == @correlation_id
    end

    def guide_observation?(rows)
      own = Array(@episode.observations).select { |item| item["correlation_id"].to_s == @correlation_id }
      text = (rows.map { |row| row.text.to_s } + own.map { |item| item["text"].to_s }).join(" ")
      text.match?(/gu[ií]a/i) && !text.match?(/retir|residuo|cerr[oó]\s+por\s+completo|no\s+volvi/i)
    end

    def unverified_line(row)
      suffix = row.turn ? " (turno #{row.turn})" : ""
      "- «#{row.text}»#{suffix}"
    end
  end
end
