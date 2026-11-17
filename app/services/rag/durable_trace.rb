# frozen_string_literal: true

module Rag
  # Durable dialogue and turn trace for every account.
  # conversation_history is replaced when a case is opened or a web trial is
  # isolated. These rows stay. A failure here never changes the technician's turn.
  # Credentials and secret headers are removed before the row is stored.
  module DurableTrace
    MESSAGE_KINDS = FieldCompanionTrace::MESSAGE_KINDS
    CONTEXT_KEY = :durable_trace_context

    module_function

    def with_context(attrs)
      previous = Thread.current[CONTEXT_KEY]
      Thread.current[CONTEXT_KEY] = (previous || {}).merge(attrs.to_h.compact)
      yield
    ensure
      Thread.current[CONTEXT_KEY] = previous
    end

    def context
      Thread.current[CONTEXT_KEY] || {}
    end

    def kind_for(role:, text:)
      body = text.to_s
      return "visual_card" if role.to_s == "assistant" && body.start_with?("[FOTO]")
      return "assistant_message" if role.to_s == "assistant"

      "user_message"
    end

    def publication_exists?(account_id:, correlation_id:, text:, kind:)
      return false if account_id.blank? || correlation_id.blank?

      FieldCompanionTrace.exists?(idempotency_key: message_key(account_id, correlation_id, kind, digest(text)))
    end

    def record_message!(session:, message:, literal:)
      return nil unless session && message.is_a?(Hash)

      account_id = session.account_id
      return nil if account_id.blank?

      text = literal.to_s
      role = message["role"].to_s
      kind = kind_for(role: role, text: text)
      correlation_id = message["correlation_id"].presence || context[:correlation_id].presence
      key = message_key(account_id, correlation_id, kind, digest(text), session_id: session.id)
      attributes = row_attributes(
        account_id: account_id,
        user_id: message["user_id"] || session.user_id || context[:user_id],
        conversation_session_id: session.id,
        episode_id: session.live_episode_id,
        correlation_id: correlation_id,
        kind: kind,
        provenance: "observed",
        content_sha256: digest(text),
        occurred_at: parse_time(message["ts"]) || Time.current,
        payload: message_payload(session, message, text)
      )
      upsert!(key, attributes) do |existing|
        merge_message!(existing, text, message)
      end
    end

    def link_turn!(account_id:, correlation_id:, episode_id:, active_photo: nil)
      return if account_id.blank? || correlation_id.blank?

      refs = attachment_refs(active_photo)
      silence do
        FieldCompanionTrace.where(
          account_id: account_id,
          correlation_id: correlation_id.to_s,
          kind: MESSAGE_KINDS
        ).find_each do |row|
          row.episode_id = episode_id.to_s if episode_id.present?
          if refs.any?
            payload = row.payload.merge("attachments" => refs)
            row.payload = payload
          end
          row.save! if row.changed?
        end
      end
      nil
    rescue StandardError => error
      Rails.logger.warn("DurableTrace link_turn #{error.class}")
      nil
    end

    def record_terminal!(account_id:, correlation_id:, outcome:, user_id: nil, conversation_session_id: nil,
                         episode_id: nil, route: nil, stage: nil, error_class: nil, original_query: nil,
                         effective_query: nil, answer: nil, chunk_ids: nil, sources: nil, photo: nil,
                         generation_mode: nil, generation_context: nil, generation_prompt_chars: nil,
                         context_truncated: nil, question_sha256: nil, attempt: nil, citations: nil)
      return nil if account_id.blank? || correlation_id.blank?

      attempt_number = (attempt || context[:attempt] || 1).to_i
      attempt_number = 1 if attempt_number < 1
      answer_text = answer.nil? ? nil : answer.to_s
      question_text = original_query.nil? ? nil : original_query.to_s
      key = "terminal:#{account_id}:#{correlation_id}:#{attempt_number}"
      payload = prepare(
        "route" => route&.to_s,
        "outcome" => outcome.to_s,
        "stage" => stage&.to_s,
        "error_class" => error_class&.to_s,
        "original_query" => question_text,
        "original_query_sha256" => digest(question_text.to_s),
        "effective_query" => (effective_query.nil? ? question_text : effective_query.to_s),
        "effective_query_sha256" => digest((effective_query.nil? ? question_text : effective_query).to_s),
        "answer" => answer_text,
        "answer_sha256" => digest(answer_text.to_s),
        "question_sha256" => question_sha256&.to_s,
        "chunk_ids" => Array(chunk_ids).map(&:to_s),
        "sources" => Array(sources),
        "citations" => Array(citations),
        "photo" => photo,
        "generation_mode" => generation_mode&.to_s,
        "generation_context" => generation_context,
        "generation_prompt_chars" => generation_prompt_chars,
        "context_truncated" => context_truncated,
        "browser_render" => "uncaptured",
        "versions" => version_stamp
      )
      attributes = row_attributes(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        episode_id: episode_id,
        correlation_id: correlation_id,
        kind: "terminal",
        provenance: "observed",
        content_sha256: digest(answer_text.to_s),
        attempt: attempt_number,
        payload: payload
      )
      upsert!(key, attributes) do |existing|
        fill_blanks!(existing, payload)
      end
    end

    def record_failure!(account_id:, correlation_id:, user_id: nil, conversation_session_id: nil,
                        episode_id: nil, stage: nil, error_class: nil, error: nil, attempt: nil,
                        outcome: "failed", job_id: nil)
      return nil if account_id.blank? || correlation_id.blank?
      return nil if error.nil? && error_class.blank? && stage.blank?

      attempt_number = (attempt || context[:attempt] || 1).to_i
      attempt_number = 1 if attempt_number < 1
      klass = error_class.presence || error&.class&.name
      stage_name = stage.presence || "error"
      key = "failure:#{account_id}:#{correlation_id}:#{attempt_number}:#{stage_name}:#{klass}"
      stack = stack_for(error)
      payload = prepare(
        "outcome" => outcome.to_s,
        "stage" => stage_name.to_s,
        "error_class" => klass&.to_s,
        "error_message" => error&.message&.to_s&.first(2_000),
        "stack" => stack,
        "stack_provenance" => stack.nil? ? "uncaptured" : "observed",
        "retried_correlation_id" => correlation_id.to_s,
        "browser_render" => "uncaptured"
      )
      upsert!(key, row_attributes(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        episode_id: episode_id,
        correlation_id: correlation_id,
        kind: "failure",
        provenance: "observed",
        attempt: attempt_number,
        job_id: job_id || context[:job_id],
        payload: payload
      )) do |existing|
        fill_blanks!(existing, payload)
      end
    end

    def record_presentation!(account_id:, correlation_id:, user_id: nil, conversation_session_id: nil,
                             episode_id: nil, cards: nil, notices: nil, response_type: nil,
                             final_state: nil, browser_render: "uncaptured")
      return nil if account_id.blank? || correlation_id.blank?

      body = prepare(
        "cards" => Array(cards),
        "notices" => Array(notices).compact,
        "response_type" => response_type&.to_s,
        "final_state" => final_state,
        "browser_render" => browser_render.presence || "uncaptured"
      )
      key = "presentation:#{account_id}:#{correlation_id}:#{digest(JSON.generate(body))}"
      upsert!(key, row_attributes(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        episode_id: episode_id,
        correlation_id: correlation_id,
        kind: "presentation",
        provenance: "observed",
        content_sha256: digest(JSON.generate(body)),
        payload: body
      ))
    end

    def record_click!(account_id:, correlation_id:, action:, user_id: nil, conversation_session_id: nil,
                      episode_id: nil, document_uid: nil, source_uri: nil, browser_render: "uncaptured")
      return nil if account_id.blank?

      cid = correlation_id.presence || "click:#{action}:#{document_uid}"
      payload = prepare(
        "action" => action.to_s,
        "document_uid" => document_uid&.to_s,
        "source_uri" => source_uri&.to_s,
        "browser_render" => browser_render.presence || "uncaptured"
      )
      key = "click:#{account_id}:#{cid}:#{action}:#{document_uid}"
      upsert!(key, row_attributes(
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        episode_id: episode_id,
        correlation_id: cid,
        kind: "click",
        provenance: "observed",
        payload: payload
      ))
    end

    def persist_capture!(events, account_id:, user_id: nil, conversation_session_id: nil, correlation_id: nil,
                         request_id: nil, job_id: nil, attempt: nil)
      return nil if account_id.blank?

      list = Array(events)
      return nil if list.empty?

      attempt_number = (attempt || context[:attempt] || 1).to_i
      attempt_number = 1 if attempt_number < 1
      identity = request_id.presence || job_id.presence || "capture"
      prepared = prepare(list)
      fingerprints = prompt_fingerprints(prepared)
      payload = prepare(
        "events" => prepared,
        "prompt_fingerprints" => fingerprints,
        "versions" => version_stamp(fingerprints),
        "browser_render" => "uncaptured"
      )
      key = "capture:#{account_id}:#{identity}:#{attempt_number}"
      upsert!(key, row_attributes(
        account_id: account_id,
        user_id: user_id || context[:user_id],
        conversation_session_id: conversation_session_id || context[:conversation_session_id],
        correlation_id: correlation_id || context[:correlation_id],
        request_id: request_id || context[:request_id],
        job_id: job_id || context[:job_id],
        kind: "capture",
        provenance: "observed",
        attempt: attempt_number,
        content_sha256: digest(JSON.generate(prepared)),
        payload: payload
      )) do |existing|
        fill_blanks!(existing, payload)
      end
    end

    def start_job(account_id:, user_id: nil, conversation_session_id: nil, correlation_id: nil,
                  job_id: nil, attempt: 1)
      owner = Thread.current[:rag_validation_capture].nil?
      if owner
        Thread.current[:rag_validation_capture] = []
        Thread.current[:rag_validation_scope] = {}
        Thread.current[:rag_validation_attempt] = attempt
        Thread.current[:rag_validation_correlation] = correlation_id if correlation_id.present?
      end
      ctx = {
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        job_id: job_id,
        attempt: attempt,
        bucket_owner: owner,
        previous_context: Thread.current[CONTEXT_KEY]
      }
      Thread.current[CONTEXT_KEY] = ctx
      if owner && defined?(ValidationCapture)
        ValidationCapture.bind(
          account_id: account_id,
          user_id: user_id,
          session_id: conversation_session_id
        )
      end
      ctx
    rescue StandardError => error
      Rails.logger.warn("DurableTrace start_job #{error.class}")
      nil
    end

    def finish_job(ctx)
      return nil unless ctx.is_a?(Hash)
      return nil unless ctx[:bucket_owner]

      events = Thread.current[:rag_validation_capture]
      persist_capture!(
        events,
        account_id: ctx[:account_id],
        user_id: ctx[:user_id],
        conversation_session_id: ctx[:conversation_session_id],
        correlation_id: ctx[:correlation_id],
        job_id: ctx[:job_id],
        attempt: ctx[:attempt]
      )
      nil
    ensure
      if ctx.is_a?(Hash) && ctx[:bucket_owner]
        Thread.current[:rag_validation_capture] = nil
        Thread.current[:rag_validation_scope] = nil
        Thread.current[:rag_validation_attempt] = nil
        Thread.current[:rag_validation_correlation] = nil
      end
      Thread.current[CONTEXT_KEY] = ctx[:previous_context] if ctx.is_a?(Hash)
    end

    # A file left by isolate_web_trial is not an original observation.
    # Re-importing the same source does not create a second copy.
    def import_recovered!(snapshot, source:)
      data = snapshot.is_a?(Hash) ? snapshot : {}
      workspace = data["workspace"].is_a?(Hash) ? data["workspace"] : {}
      account_id = workspace["account_id"]
      return [] if account_id.blank?

      history = data.dig("replaced", "conversation_history")
      history = data["conversation_history"] unless history.is_a?(Array)
      source_name = source.to_s
      source_sha = digest(source_name)
      Array(history).each_with_index.filter_map do |message, index|
        next unless message.is_a?(Hash)

        literal = message["full_content"].presence || message["prompt_reply"].presence || message["content"].to_s
        role = message["role"].to_s.presence || "user"
        kind = kind_for(role: role, text: literal)
        correlation_id = message["correlation_id"].presence || "recovered:#{workspace['conversation_session_id']}:#{index}"
        key = "recovered:#{account_id}:#{workspace['conversation_session_id']}:#{source_sha}:#{index}"
        upsert!(key, row_attributes(
          account_id: account_id,
          user_id: message["user_id"] || workspace["session_user_id"] || workspace["resolved_user_id"],
          conversation_session_id: workspace["conversation_session_id"],
          episode_id: data.dig("replaced", "active_episode", "episode_id"),
          correlation_id: correlation_id,
          kind: kind,
          provenance: "recovered",
          content_sha256: digest(literal),
          occurred_at: parse_time(message["ts"]) || parse_time(data["written_at"]) || Time.current,
          payload: prepare(
            "literal" => literal,
            "role" => role,
            "content" => message["content"],
            "full_content" => message["full_content"],
            "prompt_reply" => message["prompt_reply"],
            "recovered_from" => source_name,
            "snapshot_kind" => data["kind"],
            "snapshot_written_at" => data["written_at"],
            "browser_render" => "uncaptured"
          )
        ))
      end
    end

    def export(range:, user_ids: [], account_id: nil)
      rows = relation_for(range: range, user_ids: user_ids, account_id: account_id).order(:occurred_at, :id).to_a
      photos = photos_for(rows)
      turns = build_turns(rows, photos)
      turns.select! { |turn| turn[:account_id] == account_id } if account_id
      { turns: turns }
    end

    def archive_rows(range:, user_ids: [], account_id: nil)
      relation_for(range: range, user_ids: user_ids, account_id: account_id)
        .where(kind: MESSAGE_KINDS)
        .order(:occurred_at, :id)
        .map { |row| archive_row(row) }
    end

    def relation_for(range:, user_ids: [], account_id: nil)
      scope = FieldCompanionTrace.occurred_within(range)
      scope = scope.where(account_id:) if account_id
      ids = Array(user_ids).filter_map { |value| Integer(value, exception: false) }.uniq
      return scope if ids.empty?

      account_ids = User.where(id: ids).distinct.pluck(:account_id)
      return scope.none if account_ids.empty?

      session_ids = ConversationSession.where(account_id: account_ids, user_id: ids).pluck(:id)
      scoped = scope.where(account_id: account_ids)
      by_user = scoped.where(user_id: ids)
      return by_user if session_ids.empty?

      by_user.or(scoped.where(conversation_session_id: session_ids))
    end

    def prepare(value)
      sanitized = Rag::ValidationCapture.sanitize(json_ready(value))
      strip_transport!(sanitized)
      sanitized
    end

    def json_ready(value)
      case value
      when ActionController::Parameters
        json_ready(value.to_unsafe_h)
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key] = json_ready(item) }
      when Array
        value.map { |item| json_ready(item) }
      else
        value
      end
    end

    def deployed_version
      ENV["KAMAL_VERSION"].presence || "unreleased"
    end

    def digest(text)
      Digest::SHA256.hexdigest(text.to_s)
    end

    def message_key(account_id, correlation_id, kind, sha, session_id: nil)
      token = correlation_id.presence || "session-#{session_id}-#{sha}"
      return "user:#{account_id}:#{token}" if kind == "user_message"

      "#{kind}:#{account_id}:#{token}:#{sha}"
    end

    def message_payload(session, message, literal)
      prepare(
        "literal" => literal,
        "role" => message["role"],
        "content" => message["content"],
        "full_content" => message["full_content"],
        "full_content_truncated" => message["full_content_truncated"] == true,
        "prompt_reply" => message["prompt_reply"],
        "prompt_reply_truncated" => message["prompt_reply_truncated"] == true,
        "outcome" => message["outcome"],
        "focus_ids" => message["focus_ids"],
        "attachments" => attachment_refs(active_photo(session)),
        "browser_render" => "uncaptured",
        "versions" => version_stamp
      )
    end

    def active_photo(session)
      episode = session.active_episode
      return nil unless episode.is_a?(Hash)

      photo = episode["active_photo"]
      photo.is_a?(Hash) ? photo : nil
    end

    def attachment_refs(photo)
      return [] unless photo.is_a?(Hash) && photo["field_photo_id"].present?

      [ {
        "field_photo_id" => photo["field_photo_id"],
        "sha256" => photo["sha256"]
      }.compact ]
    end

    def merge_message!(row, literal, message)
      payload = row.payload.deep_dup
      if literal.length > payload["literal"].to_s.length
        payload["literal"] = literal
        row.content_sha256 = digest(literal)
      elsif row.kind != "user_message"
        payload["suppressed_retries"] = payload["suppressed_retries"].to_i + 1
      end
      %w[content full_content prompt_reply outcome focus_ids].each do |key|
        payload[key] = message[key] if message.key?(key) && payload[key].blank? && message[key].present?
      end
      payload["full_content_truncated"] = true if message["full_content_truncated"] == true
      payload["prompt_reply_truncated"] = true if message["prompt_reply_truncated"] == true
      row.payload = prepare(payload)
      row.save!
      row
    end

    def fill_blanks!(row, incoming)
      payload = row.payload.deep_dup
      incoming.each do |key, value|
        current = payload[key]
        payload[key] = value if current.nil? || current == "" || current == []
      end
      row.payload = payload
      row.save!
      row
    end

    def row_attributes(account_id:, kind:, payload:, user_id: nil, conversation_session_id: nil,
                       episode_id: nil, correlation_id: nil, provenance: "observed", content_sha256: nil,
                       occurred_at: nil, attempt: nil, job_id: nil, request_id: nil)
      {
        account_id: account_id,
        user_id: integer_or_nil(user_id || context[:user_id]),
        conversation_session_id: integer_or_nil(conversation_session_id || context[:conversation_session_id]),
        episode_id: episode_id&.to_s.presence,
        correlation_id: correlation_id&.to_s.presence,
        request_id: (request_id || context[:request_id])&.to_s.presence,
        job_id: (job_id || context[:job_id])&.to_s.presence,
        attempt: attempt || context[:attempt],
        kind: kind,
        provenance: provenance,
        content_sha256: content_sha256,
        deployed_version: deployed_version,
        occurred_at: occurred_at || Time.current,
        payload: payload.is_a?(Hash) || payload.is_a?(Array) ? payload : { "value" => payload }
      }
    end

    def upsert!(key, attributes)
      silence do
        ApplicationRecord.transaction(requires_new: true) do
          row = FieldCompanionTrace.lock.find_by(idempotency_key: key)
          if row
            yield row if block_given?
            row
          else
            FieldCompanionTrace.create!(attributes.merge(idempotency_key: key))
          end
        end
      end
    rescue ActiveRecord::RecordNotUnique
      FieldCompanionTrace.find_by(idempotency_key: key)
    rescue StandardError => error
      Rails.logger.warn("DurableTrace write #{error.class}")
      nil
    end

    def version_stamp(fingerprints = nil)
      {
        "deployed_version" => deployed_version,
        "code" => code_versions,
        "sent_prompts" => Array(fingerprints),
        "sent_prompts_provenance" => Array(fingerprints).any? ? "observed" : "uncaptured"
      }
    end

    def code_versions
      {
        "turn_perception_prompt" => Rag::TurnPerception::PROMPT_VERSION,
        "turn_perception_schema" => Rag::TurnPerception::SCHEMA_VERSION
      }
    rescue StandardError
      {}
    end

    def prompt_fingerprints(events)
      found = []
      Array(events).each do |event|
        next unless event.is_a?(Hash)

        event.each do |key, value|
          name = key.to_s
          if name == "prompt_version" && value.present?
            found << { "name" => "prompt_version", "version" => value.to_s }
          elsif name.match?(/prompt.*sha256|sha256.*prompt/) && value.present?
            found << { "name" => name, "sha256" => value.to_s }
          end
        end
      end
      found.uniq
    end

    def stack_for(error)
      return nil unless error.respond_to?(:backtrace)

      root = Rails.root.to_s
      lines = Array(error.backtrace).select { |line| line.to_s.start_with?(root) }.first(30)
      lines.presence
    end

    def strip_transport!(value)
      case value
      when Hash
        value.delete("headers")
        value.delete("HTTP_HEADERS")
        value.keys.each do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
          if normalized.match?(/\A(cookie|setcookie|authorization|proxyauthorization|xapikey|xamzsecuritytoken|httpcookie|httpauthorization)\z/)
            value.delete(key)
          else
            strip_transport!(value[key])
          end
        end
      when Array
        value.each { |item| strip_transport!(item) }
      end
      value
    end

    def photos_for(rows)
      ids = []
      account_ids = []
      rows.each do |row|
        account_ids << row.account_id
        Array(row.payload["attachments"]).each do |item|
          ids << item["field_photo_id"] if item.is_a?(Hash)
        end
      end
      return {} if ids.empty?

      FieldPhoto.where(account_id: account_ids.uniq, id: ids.compact.uniq).index_by(&:id)
    end

    def build_turns(rows, photos)
      buckets = Hash.new { |hash, key| hash[key] = [] }
      captures = []
      rows.each do |row|
        if row.kind == "capture"
          captures << row
        else
          buckets[row.correlation_id.presence || "unlinked:#{row.id}"] << row
        end
      end
      captures.each do |capture|
        cids = Array(capture.payload["events"]).filter_map { |event|
          event["correlation_id"].presence if event.is_a?(Hash)
        }.uniq
        cids = [ capture.correlation_id.presence || "capture:#{capture.id}" ] if cids.empty?
        cids.each { |cid| buckets[cid] }
      end
      buckets.map { |correlation_id, group| build_turn(correlation_id, group, captures, photos) }
        .sort_by { |turn| [ turn[:occurred_at].to_s, turn[:correlation_id].to_s ] }
    end

    def build_turn(correlation_id, rows, captures, photos)
      events = events_for(correlation_id, rows, captures)
      messages = rows.select { |row| MESSAGE_KINDS.include?(row.kind) }
      terminals = rows.select { |row| row.kind == "terminal" }
      failures = rows.select { |row| row.kind == "failure" }
      presentations = rows.select { |row| row.kind == "presentation" }
      clicks = rows.select { |row| row.kind == "click" }
      user_row = preferred_message(messages, "user_message")
      card_row = preferred_message(messages, "visual_card")
      answer_row = preferred_message(messages, "assistant_message")
      terminal = terminals.max_by { |row| [ row.attempt.to_i, row.occurred_at ] }
      photo = linked_photo(messages, photos)
      technician = text_section(user_row, "literal")
      technician = terminal_text(terminal, "original_query") if technician[:provenance] == "uncaptured"
      visual_card = text_section(card_row, "literal")
      technical = technical_response(answer_row, terminal)
      interpretation = event_section(events, %w[perception_applied interpreter_raw])
      state_change = event_section(events, %w[episode_delta])
      focus = focus_section(events, clicks)
      retrieval = retrieval_section(events)
      model = model_section(events)
      presentation = presentation_section(presentations, clicks, terminal)
      versions = merged_versions(rows, captures, events)
      occurred = (rows + matching_captures(correlation_id, rows, captures)).filter_map(&:occurred_at).min
      provenance = turn_provenance(messages + terminals + failures)
      turn = {
        account_id: (rows.first || matching_captures(correlation_id, rows, captures).first)&.account_id,
        user_id: rows.filter_map(&:user_id).first,
        conversation_session_id: rows.filter_map(&:conversation_session_id).first,
        episode_id: rows.filter_map { |row| row.episode_id.presence }.last,
        field_case_id: events.filter_map { |event| event["field_case_id"] }.first,
        field_turn_id: events.filter_map { |event| event["field_turn_id"] }.first,
        correlation_id: correlation_id,
        request_id: rows.filter_map { |row| row.request_id.presence }.first,
        job_id: rows.filter_map { |row| row.job_id.presence }.first,
        occurred_at: occurred&.iso8601,
        provenance: provenance,
        deployed_version: versions["deployed_version"],
        versions: versions,
        technician_message: technician,
        attachments: attachment_export(messages, photo),
        visual_observation: captured_photo_observation(events) || observation_export(photo, card_row),
        visual_card: visual_card,
        technical_response: technical,
        attempts: attempt_export(failures, terminals),
        interpretation: interpretation,
        state_change: state_change,
        focus: focus,
        retrieval: retrieval,
        model: model,
        presentation: presentation,
        publication: publication_section(terminal, answer_row),
        integrity: integrity_section(technician, technical, terminal),
        browser_render: "uncaptured"
      }
      turn[:recovered_from] = recovered_sources(messages)
      turn[:uncaptured_fields] = uncaptured_fields(turn)
      turn
    end

    def events_for(correlation_id, rows, captures)
      request_ids = rows.filter_map { |row| row.request_id.presence }.uniq
      job_ids = rows.filter_map { |row| row.job_id.presence }.uniq
      selected = []
      captures.each do |capture|
        next unless capture_matches?(capture, correlation_id, request_ids, job_ids)

        Array(capture.payload["events"]).each do |event|
          next unless event.is_a?(Hash)

          cid = event["correlation_id"].presence
          next if event["account_id"].present? && event["account_id"].to_s != capture.account_id.to_s

          if cid.blank? || cid == correlation_id || event["correlation_root"] == correlation_id
            selected << event.merge("attempt" => event["attempt"] || capture.attempt)
          end
        end
      end
      selected
    end

    def capture_matches?(capture, correlation_id, request_ids, job_ids)
      return true if capture.correlation_id.present? && capture.correlation_id == correlation_id
      return true if capture.request_id.present? && request_ids.include?(capture.request_id)
      return true if capture.job_id.present? && job_ids.include?(capture.job_id)

      Array(capture.payload["events"]).any? { |event|
        event.is_a?(Hash) && event["correlation_id"].to_s == correlation_id
      }
    end

    def matching_captures(correlation_id, rows, captures)
      request_ids = rows.filter_map { |row| row.request_id.presence }
      job_ids = rows.filter_map { |row| row.job_id.presence }
      captures.select { |capture| capture_matches?(capture, correlation_id, request_ids, job_ids) }
    end

    def preferred_message(messages, kind)
      pool = messages.select { |row| row.kind == kind }
      pool.reverse.find { |row| row.provenance == "observed" } || pool.last
    end

    def text_section(row, key)
      return { provenance: "uncaptured" } unless row

      text = row.payload[key].to_s
      text = row.payload["full_content"].to_s if text.blank?
      text = row.payload["content"].to_s if text.blank?
      return { provenance: "uncaptured", stored_provenance: row.provenance } if text.blank?

      {
        text: text,
        sha256: digest(text),
        stored_sha256: row.content_sha256,
        provenance: row.provenance,
        truncated: row.payload["full_content_truncated"] == true,
        suppressed_retries: row.payload["suppressed_retries"].to_i
      }
    end

    def terminal_text(terminal, key)
      return { provenance: "uncaptured" } unless terminal

      text = terminal.payload[key]
      return { provenance: "uncaptured", sha256: terminal.payload["#{key}_sha256"] } if text.blank?

      { text: text.to_s, sha256: digest(text.to_s), provenance: terminal.provenance }
    end

    def technical_response(answer_row, terminal)
      section = text_section(answer_row, "literal")
      if section[:provenance] == "uncaptured"
        section = terminal_text(terminal, "answer")
        section[:published_to_history] = false if section[:text].present?
      else
        section[:published_to_history] = true
      end
      if terminal
        section[:outcome] = terminal.payload["outcome"]
        section[:citations] = terminal.payload["citations"].presence || terminal.payload["sources"]
        section[:generation_mode] = terminal.payload["generation_mode"]
        section[:format] = "marked_citations" if section[:text].to_s.match?(/\[\d+\]/)
      end
      section[:outcome] ||= answer_row&.payload&.[]("outcome")
      section
    end

    def event_section(events, kinds)
      matched = events.select { |event| kinds.include?(event["kind"]) }
      return { provenance: "uncaptured" } if matched.empty?

      { events: matched, provenance: "observed" }
    end

    def focus_section(events, clicks)
      matched = events.select { |event| event["kind"] == "document_focus" }
      pins = clicks.select { |row| row.payload["action"].to_s.include?("focus") }
      return { provenance: "uncaptured" } if matched.empty? && pins.empty?

      {
        events: matched,
        changes: pins.map { |row| row.payload.slice("action", "document_uid", "source_uri") },
        provenance: "observed"
      }
    end

    def captured_photo_observation(events)
      event = events.reverse.find { |row| row["kind"] == "photo_observation" }
      return unless event

      { provenance: "observed", observation: event["observation"], analysis: event["visual_analysis"],
        status: event["status"], reason: event["reason"] }
    end

    def retrieval_section(events)
      queries = events.select { |event| CaptureLayers::QUERY_KINDS.include?(event["kind"]) }
      candidates = events.select { |event| event["kind"] == "retrieval_results" }
      rerank = events.select { |event| event["kind"] == "companion_rerank" }
      evidence = CaptureLayers.evidence(events)
      {
        queries: queries,
        candidates: candidates,
        rerank: rerank,
        generator_evidence: evidence,
        queries_provenance: presence(queries),
        candidates_provenance: presence(candidates),
        rerank_provenance: presence(rerank),
        generator_evidence_provenance: presence(evidence)
      }
    end

    def model_section(events)
      matched = events.select { |event|
        %w[model_call interpreter_request interpreter_raw converse retrieve_and_generate companion_direct companion_plan].include?(event["kind"])
      }
      return { input_provenance: "uncaptured", output_provenance: "uncaptured", provenance: "uncaptured" } if matched.empty?

      input = matched.filter_map { |event| event["input"].presence || event["prompt"].presence || event["system"].presence }.join("\n")
      output = CaptureLayers.model_outputs(matched).map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join("\n")
      {
        events: matched,
        companion_direct: CaptureLayers.companion_status(matched, "companion_direct"),
        companion_plan: CaptureLayers.companion_status(matched, "companion_plan"),
        input: input.presence,
        input_sha256: (digest(input) if input.present?),
        input_provenance: input.present? ? "observed" : "uncaptured",
        output: output.presence,
        output_sha256: (digest(output) if output.present?),
        output_provenance: output.present? ? "observed" : "uncaptured",
        provenance: "observed"
      }
    end

    def presentation_section(presentations, clicks, terminal)
      return { browser_render: "uncaptured", provenance: "uncaptured" } if presentations.empty? && clicks.empty? && terminal.nil?

      cards = presentations.flat_map { |row| Array(row.payload["cards"]) }
      notices = presentations.flat_map { |row| Array(row.payload["notices"]) }
      response_type = presentations.filter_map { |row| row.payload["response_type"].presence }.last
      response_type ||= terminal&.payload&.[]("generation_mode")
      final_state = presentations.filter_map { |row| row.payload["final_state"] }.last
      final_state ||= terminal&.payload&.[]("outcome")
      {
        cards: cards,
        notices: notices,
        response_type: response_type,
        final_state: final_state,
        clicks: clicks.map { |row|
          row.payload.slice("action", "document_uid", "source_uri").merge("occurred_at" => row.occurred_at&.iso8601)
        },
        browser_render: "uncaptured",
        provenance: presentations.any? || clicks.any? || terminal.present? ? "observed" : "uncaptured"
      }
    end

    def publication_section(terminal, answer_row)
      return { provenance: "uncaptured" } unless terminal || answer_row

      {
        outcome: terminal&.payload&.[]("outcome") || answer_row&.payload&.[]("outcome"),
        stage: terminal&.payload&.[]("stage"),
        generation_mode: terminal&.payload&.[]("generation_mode"),
        published_to_history: answer_row.present?,
        suppressed_retries: answer_row&.payload&.[]("suppressed_retries").to_i,
        provenance: "observed"
      }
    end

    def integrity_section(technician, technical, terminal)
      answer = technical[:text]
      {
        question_sha256: technician[:sha256] || technician[:stored_sha256] || terminal&.payload&.[]("original_query_sha256"),
        answer_sha256: (digest(answer) if answer.present?) || terminal&.payload&.[]("answer_sha256"),
        stored_answer_sha256: terminal&.payload&.[]("answer_sha256"),
        match: (answer.present? && terminal&.payload&.[]("answer_sha256").present? ?
          digest(answer) == terminal.payload["answer_sha256"] : nil)
      }
    end

    def attempt_export(failures, terminals)
      rows = failures.map { |row|
        {
          attempt: row.attempt,
          job_id: row.job_id,
          outcome: row.payload["outcome"] || "failed",
          stage: row.payload["stage"],
          error_class: row.payload["error_class"],
          error_message: row.payload["error_message"],
          stack: row.payload["stack"],
          stack_provenance: row.payload["stack_provenance"] || (row.payload["stack"].present? ? "observed" : "uncaptured"),
          occurred_at: row.occurred_at&.iso8601,
          correlation_id: row.correlation_id,
          kind: "failure"
        }
      }
      terminals.each do |row|
        rows << {
          attempt: row.attempt,
          job_id: row.job_id,
          outcome: row.payload["outcome"],
          stage: row.payload["stage"],
          error_class: row.payload["error_class"],
          answer: row.payload["answer"],
          answer_sha256: row.payload["answer_sha256"],
          occurred_at: row.occurred_at&.iso8601,
          correlation_id: row.correlation_id,
          kind: "terminal"
        }
      end
      rows.sort_by { |row| [ row[:attempt].to_i, row[:kind].to_s, row[:occurred_at].to_s ] }
    end

    def linked_photo(messages, photos)
      ids = messages.flat_map { |row|
        Array(row.payload["attachments"]).filter_map { |item| item["field_photo_id"] if item.is_a?(Hash) }
      }
      ids.filter_map { |id| photos[id.to_i] }.first
    end

    def attachment_export(messages, photo)
      refs = messages.flat_map { |row| Array(row.payload["attachments"]) }.select { |item| item.is_a?(Hash) }
      refs = refs.uniq { |item| item["field_photo_id"] }
      return [ { provenance: "uncaptured" } ] if refs.empty? && photo.nil?

      refs.map do |item|
        record = photo if photo && photo.id.to_s == item["field_photo_id"].to_s
        item.merge(
          "content_type" => record&.content_type,
          "byte_size" => record&.byte_size,
          "provenance" => "observed"
        ).compact
      end
    end

    def observation_export(photo, card_row)
      return { provenance: "uncaptured" } unless photo

      observation = photo.visual_observation
      {
        field_photo_id: photo.id,
        sha256: photo.sha256,
        episode_linked: card_row&.episode_id.present? || photo.conversation_session_id.present?,
        observation: observation,
        observation_sha256: (digest(JSON.generate(observation)) if observation.present?),
        provenance: observation.present? ? "observed" : "uncaptured"
      }
    end

    def merged_versions(rows, captures, events)
      stamp = version_stamp(prompt_fingerprints(events))
      (rows + captures).each do |row|
        versions = row.payload["versions"]
        next unless versions.is_a?(Hash)

        stamp["sent_prompts"] = (Array(stamp["sent_prompts"]) + Array(versions["sent_prompts"])).uniq
      end
      stamp["sent_prompts_provenance"] = stamp["sent_prompts"].any? ? "observed" : "uncaptured"
      stamp["deployed_version"] = rows.filter_map(&:deployed_version).first || deployed_version
      stamp
    end

    def turn_provenance(rows)
      labels = rows.map(&:provenance).uniq
      return "uncaptured" if labels.empty?
      return labels.first if labels.one?

      labels.include?("recovered") ? "mixed" : labels.first
    end

    def recovered_sources(rows)
      rows.filter_map { |row| row.payload["recovered_from"].presence if row.provenance == "recovered" }.uniq
    end

    def uncaptured_fields(turn)
      missing = []
      missing << "technician_message" if turn.dig(:technician_message, :provenance) == "uncaptured" || turn.dig(:technician_message, :text).blank?
      missing << "attachments" if Array(turn[:attachments]).all? { |item| item[:provenance] == "uncaptured" || item["provenance"] == "uncaptured" }
      missing << "visual_observation" if turn.dig(:visual_observation, :provenance) == "uncaptured"
      missing << "interpretation" if turn.dig(:interpretation, :provenance) == "uncaptured"
      missing << "state_change" if turn.dig(:state_change, :provenance) == "uncaptured"
      missing << "focus" if turn.dig(:focus, :provenance) == "uncaptured"
      missing << "retrieval_query" if turn.dig(:retrieval, :queries_provenance) == "uncaptured"
      missing << "retrieval_candidates" if turn.dig(:retrieval, :candidates_provenance) == "uncaptured"
      missing << "rerank" if turn.dig(:retrieval, :rerank_provenance) == "uncaptured"
      missing << "generator_evidence" if turn.dig(:retrieval, :generator_evidence_provenance) == "uncaptured"
      missing << "model_input" if turn.dig(:model, :input_provenance) == "uncaptured"
      missing << "model_output" if turn.dig(:model, :output_provenance) == "uncaptured"
      missing << "final_answer" if turn.dig(:technical_response, :text).blank?
      missing << "presentation" if turn.dig(:presentation, :provenance) == "uncaptured"
      missing << "browser_render"
      missing << "failure_stack" if Array(turn[:attempts]).any? { |row|
        row[:kind] == "failure" && row[:stack_provenance] == "uncaptured"
      }
      missing
    end

    def archive_row(row)
      literal = row.payload["literal"].presence || row.payload["full_content"].presence || row.payload["content"].to_s
      archived = {
        session_id: row.conversation_session_id,
        account_id: row.account_id,
        user_id: row.user_id,
        correlation_id: row.correlation_id,
        role: row.kind == "user_message" ? "user" : "assistant",
        content: literal,
        full_content: literal,
        ts: row.occurred_at,
        provenance: row.provenance,
        content_sha256: row.content_sha256 || digest(literal)
      }
      archived[:prompt_reply] = row.payload["prompt_reply"].to_s if row.payload.key?("prompt_reply") && row.payload["prompt_reply"].present?
      archived[:recovered_from] = row.payload["recovered_from"] if row.provenance == "recovered"
      archived
    end

    def presence(list)
      list.any? ? "observed" : "uncaptured"
    end

    def integer_or_nil(value)
      Integer(value, exception: false)
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def silence
      logger = ActiveRecord::Base.logger
      if logger.respond_to?(:silence)
        logger.silence { yield }
      else
        yield
      end
    end
  end
end
