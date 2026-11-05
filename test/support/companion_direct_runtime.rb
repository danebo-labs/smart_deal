# frozen_string_literal: true

# The stub runtime is installed only while a direct test is running.
# A permanent prepend shadows every other BedrockRagService.new stub.

class CompanionDirectHost
  include RagQueryConcern

  def initialize(account, user)
    @current_account = account
    @current_user = user
  end

  attr_reader :current_account, :current_user

  def ask(question, **)
    execute_rag_query(question, **)
  end
end

module CompanionDirectRuntime
  def install_companion_direct_runtime!
    previous = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) do |*args, **kwargs, &block|
      service = previous.call(*args, **kwargs, &block)
      runtime = Thread.current[:companion_direct_runtime]
      kb = Thread.current[:companion_direct_kb]
      if runtime && kb
        service.instance_variable_set(:@client, kb.client)
        generator = AiProvider.new
        generator.instance_variable_get(:@client).instance_variable_set(:@client, runtime)
        service.instance_variable_set(:@document_identity_generator, generator)
        Thread.current[:companion_direct_service] = service
      end
      service
    end
    @companion_direct_previous_new = previous
  end

  def remove_companion_direct_runtime!
    previous = @companion_direct_previous_new
    return unless previous

    BedrockRagService.define_singleton_method(:new) do |*args, **kwargs, &block|
      previous.call(*args, **kwargs, &block)
    end
    @companion_direct_previous_new = nil
  end

  def bind_recorded_converse(runtime)
    method = runtime.method(:converse)
    method = method.super_method while method && method.owner.name.nil?
    raise "sdk converse missing" if method.nil?

    unbound = method.unbind
    runtime.define_singleton_method(:converse) do |params = {}, options = {}|
      unbound.bind_call(self, params, options)
    end
  end

  def request_hash(params)
    return {} if params.nil?
    return params if params.is_a?(Hash)

    params.respond_to?(:to_h) ? params.to_h : {}
  end

  def request_messages(params)
    Array(request_hash(params)[:messages]).map { |message| message.respond_to?(:to_h) && !message.is_a?(Hash) ? message.to_h : message }
  end

  def request_text(params)
    request_messages(params).map { |message|
      Array(message[:content]).map { |block|
        block = block.to_h if block.respond_to?(:to_h) && !block.is_a?(Hash)
        block[:text] || block["text"]
      }.join
    }.join("\n")
  end

  def request_roles(params)
    request_messages(params).map { |message| (message[:role] || message["role"]).to_s }
  end

  def text_reply(body, stop: "end_turn")
    {
      output: { message: { role: "assistant", content: [ { text: body } ] } },
      stop_reason: stop,
      usage: { input_tokens: 120, output_tokens: 40, total_tokens: 160 },
      metrics: { latency_ms: 5 }
    }
  end
end
