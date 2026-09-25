# frozen_string_literal: true

# Production replay of script/fixtures/production_conversational_baseline_v2.json.
#
# Verifies the approved conversational closure on the running web container:
# switch and correct persist a catalog-consensus model, an unknown target
# stays fail-closed, "el otro" clears the model, continue keeps the cable
# goal, and the MonoSpace brake follow-up does not cite MiniSpace.
#
# Uses one isolated user on danebo-pilot-elevator and that user's web
# session. It does not read or write script/fixtures/haiku_semantic_perception_p0.jsonl.
# The user and session are deleted before the process exits.
#
# The fixture is read from the deployed image (14 flows, 29 question turns).
# Do not edit those questions. This run is an engineering check, not a
# release gate.
#
# Pass: BASELINE_RESULT pass, exit 0.
# Fail: BASELINE_RESULT fail, or any exception, exit non-zero.
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e PRODUCTION_BASELINE_REPLAY=1 $CID bin/rails runner -" \
#     < script/production_conversational_baseline_v2.rb

module ProductionConversationalBaselineV2
  FIXTURE = "script/fixtures/production_conversational_baseline_v2.json"

  def self.failures(rows)
    questions = Array(rows).select { |row| row["question"].is_a?(String) }
    problems = []
    problems << "turns=#{questions.size}" unless questions.size == 29
    flow_count = questions.pluck("flow_id").uniq.size
    problems << "flows=#{flow_count}" unless flow_count == 14
    questions.each do |row|
      problems << "#{row["flow_id"]}##{row["turn"]} http=#{row["http"]}" unless row["http"] == 200
    end
    problems.concat(behavior_failures(questions))
    problems
  end

  def self.behavior_failures(questions)
    problems = []
    expect(questions, problems, "CONTINUE", 2) { |row| row["goal_after"].to_s.include?("fijación de cables") }
    expect(questions, problems, "SWITCH", 2) { |row| row["model_after"] == "MiniSpace" && row["ownership_applied"] == true }
    expect(questions, problems, "CORRECT", 2) { |row| row["model_after"] == "MiniSpace" && row["ownership_applied"] == true }
    expect(questions, problems, "MODEL_VALUE_FREEZE", 2) { |row| row["model_after"] == "MonoSpace" }
    expect(questions, problems, "REAFFIRMATION", 2) { |row| row["model_after"] == "MonoSpace" }
    expect(questions, problems, "AMBIGUOUS_FAIL_CLOSED", 2) { |row| row["model_after"].nil? }
    expect(questions, problems, "FAILURE_PATH", 2) { |row| row["model_after"].nil? }
    expect(questions, problems, "CATALOG_MISS", 2) { |row| row["model_after"].nil? && row["ownership_applied"] == false }
    expect(questions, problems, "MULTI_TURN_STALE_CONTEXT", 4) do |row|
      prior = find(questions, "MULTI_TURN_STALE_CONTEXT", 3)
      row["model_after"] == "MonoSpace" && prior && row["episode_id"] != prior["episode_id"]
    end
    expect(questions, problems, "MULTI_TURN_STALE_CONTEXT", 5) do |row|
      titles = Array(row["citations"])
      row["model_after"] == "MonoSpace" &&
        titles.any? { |title| title.match?(/monospace/i) } &&
        titles.none? { |title| title.match?(/minispace/i) }
    end
    problems
  end

  def self.expect(questions, problems, flow_id, turn)
    row = find(questions, flow_id, turn)
    return problems << "#{flow_id}##{turn} missing" unless row
    return if yield(row)

    problems << "#{flow_id}##{turn} model=#{row["model_after"].inspect} ownership=#{row["ownership_applied"].inspect}"
  end

  def self.find(questions, flow_id, turn)
    questions.find { |row| row["flow_id"] == flow_id && row["turn"] == turn }
  end

  def self.replay!
    account = Account.find_by!(slug: "danebo-pilot-elevator")
    password = SecureRandom.hex(12)
    user = User.create!(
      email: "smoke-baseline-#{SecureRandom.hex(3)}@danebo.ai",
      password: password,
      password_confirmation: password,
      account: account
    )
    code = 1
    begin
      app = ActionDispatch::Integration::Session.new(Rails.application)
      app.host! "piloto.danebo.ai"
      app.https!
      ActionController::Base.allow_forgery_protection = false
      app.post "/users/sign_in", params: { user: { email: user.email, password: password } }
      raise "login failed status=#{app.response.status}" unless [ 200, 302, 303 ].include?(app.response.status)

      rows = play(app, user)
      rows.each { |row| $stdout.puts(JSON.generate(row)) }
      problems = failures(rows)
      if problems.empty?
        $stdout.puts("BASELINE_RESULT pass flows=14 turns=29")
        code = 0
      else
        problems.each { |problem| $stdout.puts("BASELINE_FAILURE #{problem}") }
        $stdout.puts("BASELINE_RESULT fail")
      end
    ensure
      if user&.persisted?
        ConversationSession.where(user_id: user.id).delete_all
        user.destroy!
      end
      $stdout.puts("SMOKE_USER_DELETED")
    end
    code
  end

  def self.play(app, user)
    corpus = JSON.parse(Rails.root.join(FIXTURE).read)
    rows = []
    corpus.fetch("flows").each do |flow|
      clear_episode!(user)
      turn_n = 0
      flow.fetch("turns").each do |step|
        if step.is_a?(Hash) && step["clear_episode"]
          clear_episode!(user)
          next
        end
        turn_n += 1
        before = snapshot(user)
        result = ask(app, step)
        after = snapshot(user)
        rows << turn_row(flow.fetch("id"), turn_n, step, before, after, result)
      end
    end
    rows
  end

  def self.turn_row(flow_id, turn_n, question, before, after, result)
    own = result[:ownership] || {}
    shadow = result[:shadow] || {}
    {
      "flow_id" => flow_id,
      "turn" => turn_n,
      "question" => question,
      "http" => result[:http],
      "relation" => own["relation"] || shadow["relation"],
      "ambiguous" => own.key?("ambiguous") ? own["ambiguous"] : shadow["ambiguous"],
      "ownership_applied" => own["ownership_applied"] == true,
      "episode_decision" => result.dig(:companion, "result"),
      "model_before" => before[:model],
      "model_after" => after[:model],
      "goal_after" => after[:goal],
      "episode_id" => after[:episode_id],
      "citations" => result[:citations],
      "analysis_error" => own["analysis_error"]
    }
  end

  def self.clear_episode!(user)
    ConversationSession.uncached do
      ConversationSession.where(user_id: user.id, channel: "web").find_each do |row|
        row.update_columns(active_episode: {}) # rubocop:disable Rails/SkipsModelValidations -- cached {} skips update!
      end
    end
  end

  def self.snapshot(user)
    row = ConversationSession.uncached do
      ConversationSession.where(user_id: user.id, channel: "web").order(:id).first&.reload
    end
    state = row&.active_episode || {}
    goal = state["goal"]
    {
      episode_id: state["episode_id"],
      model: state.dig("facts", "model", "value"),
      goal: goal.is_a?(Hash) ? goal["text"] : goal
    }
  end

  def self.ask(app, question)
    io = StringIO.new
    logger = Logger.new(io)
    Rails.logger.broadcast_to(logger)
    app.post "/rag/ask", params: { question: question }, as: :json, headers: { "Accept" => "application/json" }
    body = JSON.parse(app.response.body)
    logs = io.string
    usage = logs.scan(/\[PILOT_USAGE\] (\{.*\})/).flatten.filter_map { |line| JSON.parse(line) rescue nil }
    ownership = logs.scan(/\{[^\n]*"event":"haiku_ownership_slice"[^\n]*\}/).last
    shadow = logs.scan(/\{[^\n]*"event":"haiku_query_analysis_shadow"[^\n]*\}/).last
    titles = Array(body["citations"]).filter_map { |item| item["title"] if item.is_a?(Hash) }
    {
      http: app.response.status,
      citations: titles,
      ownership: ownership ? JSON.parse(ownership) : nil,
      shadow: shadow ? JSON.parse(shadow) : nil,
      companion: usage.reverse.find { |event| event["event"] == "field_companion_turn" && event["result"] != "assistant" }
    }
  rescue JSON::ParserError
    { http: app.response.status, citations: [], ownership: nil, shadow: nil, companion: nil }
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end

exit ProductionConversationalBaselineV2.replay! if ENV["PRODUCTION_BASELINE_REPLAY"] == "1"
