# app/services/bedrock_rag_service.rb

require "aws-sdk-bedrockagentruntime"
require "aws-sdk-core/static_token_provider"
require "json"

class BedrockRagService
  def initialize
    region = Rails.application.credentials.dig(:aws, :region) || 
             ENV.fetch("AWS_REGION", "us-east-1")
    
    # Get credentials from Rails credentials or environment variables
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                   ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                   ENV["AWS_BEDROCK_BEARER_TOKEN"]
    
    client_options = { region: region }
    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end

    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @knowledge_base_id = Rails.application.credentials.dig(:bedrock, :knowledge_base_id) ||
                         ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    
    # Use Claude 3 Sonnet with foundation-model ARN (works reliably with Knowledge Base)
    # Alternative: Can use Claude 3 Opus or other models that support foundation-model ARN
    default_model_id = ENV.fetch("BEDROCK_MODEL_ID", "anthropic.claude-3-sonnet-20240229-v1:0")
    model_id = Rails.application.credentials.dig(:bedrock, :model_id) || default_model_id
    
    # Remove 'us.' prefix if present (not needed for foundation-model ARN)
    model_id = model_id.gsub(/^us\./, '') if model_id.start_with?('us.')
    
    # Build foundation-model ARN for Knowledge Base
    # Format: arn:aws:bedrock:{region}::foundation-model/{model_id}
    # Example: arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0
    @model_arn = "arn:aws:bedrock:#{region}::foundation-model/#{model_id}"
    
    # Debug logging
    Rails.logger.info("BedrockRagService initialized - Knowledge Base ID: #{@knowledge_base_id.present? ? @knowledge_base_id : 'NOT SET'}")
    Rails.logger.info("BedrockRagService initialized - Model ARN: #{@model_arn}")
  end

  # Query the Knowledge Base using RAG
  def query(question, model_arn: nil, max_tokens: 2000, temperature: 0.7)
    unless @knowledge_base_id
      error_msg = "Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials."
      Rails.logger.error(error_msg)
      raise error_msg
    end

    # Use provided ARN or default from initialization
    model_arn ||= @model_arn

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    response = @client.retrieve_and_generate({
      input: {
        text: question
      },
      retrieve_and_generate_configuration: {
        type: "KNOWLEDGE_BASE",
        knowledge_base_configuration: {
          knowledge_base_id: @knowledge_base_id,
          model_arn: model_arn  # Use foundation-model ARN (e.g., Claude 3 Sonnet)
        }
      }
    })

    Rails.logger.info("Knowledge Base response received successfully")
    
    # Log citations for debugging
    if response.citations && response.citations.any?
      Rails.logger.info("Found #{response.citations.length} citation(s):")
      response.citations.each_with_index do |citation, index|
        if citation.retrieved_references && citation.retrieved_references.any?
          citation.retrieved_references.each do |ref|
            file_name = ref.location&.uri&.split('/')&.last || 'Unknown'
            Rails.logger.info("  Citation #{index + 1}: #{file_name} (URI: #{ref.location&.uri})")
          end
        end
      end
    else
      Rails.logger.warn("No citations found in response")
    end

    # Format citations for easier display
    formatted_citations = []
    if response.citations && response.citations.any?
      response.citations.each do |citation|
        if citation.retrieved_references && citation.retrieved_references.any?
          citation.retrieved_references.each do |ref|
            file_name = ref.location&.uri&.split('/')&.last || 'Documento sin nombre'
            formatted_citations << {
              file_name: file_name,
              uri: ref.location&.uri,
              content: ref.content&.text&.truncate(200) # Primeros 200 caracteres del contenido
            }
          end
        end
      end
    end

    {
      answer: response.output.text,
      citations: formatted_citations,
      session_id: response.session_id
    }
  rescue => e
    Rails.logger.error("Bedrock RAG error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise "Failed to query Knowledge Base: #{e.message}"
  end

  # Alternative: Use Retrieve API to get sources, then generate with BedrockClient
  # This gives more control over the generation process
  def query_with_sources(question, model_id: nil, max_tokens: 2000, temperature: 0.7)
    raise "Knowledge Base ID not configured" unless @knowledge_base_id

    # Step 1: Retrieve relevant chunks from Knowledge Base
    retrieve_response = @client.retrieve({
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: {
        text: question
      },
      retrieval_configuration: {
        vector_search_configuration: {
          numberOfResults: 5, # Get top 5 most relevant chunks
          override_search_type: "SEMANTIC"
        }
      }
    })

    # Step 2: Build context from retrieved chunks
    context_chunks = retrieve_response.retrieval_results.map do |result|
      {
        content: result.content.text,
        metadata: result.metadata,
        score: result.score
      }
    end

    # Step 3: Build prompt with context
    context_text = context_chunks.map { |chunk| chunk[:content] }.join("\n\n---\n\n")
    
    prompt = <<~PROMPT
      Eres un asistente experto que responde preguntas basándose únicamente en el contexto proporcionado.

      Contexto de los documentos:
      #{context_text}

      Instrucciones:
      - Responde la pregunta del usuario basándote ÚNICAMENTE en el contexto proporcionado
      - Si la información no está en el contexto, di claramente que no tienes esa información
      - Responde en el mismo idioma que la pregunta
      - Sé conciso pero completo

      Pregunta del usuario: #{question}

      Respuesta:
    PROMPT

    # Step 4: Generate answer using BedrockClient
    bedrock_client = BedrockClient.new
    answer = bedrock_client.generate_text(prompt, model_id: model_id, max_tokens: max_tokens, temperature: temperature)

    {
      answer: answer,
      sources: context_chunks.map { |chunk| chunk[:metadata] }.compact,
      citations: context_chunks.length
    }
  rescue => e
    Rails.logger.error("Bedrock RAG error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise "Failed to query Knowledge Base: #{e.message}"
  end
end

