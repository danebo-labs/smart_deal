# frozen_string_literal: true

# app/services/sql_generation_service.rb
#
# A specialized service to handle the Text-to-SQL workflow.
# It is only called when the QueryOrchestratorService determines the user's
# question requires data from the client's business database.
#
# Workflow:
#   1. Read the database schema automatically
#   2. Ask the LLM to generate SQL based on the schema and user question
#   3. Execute the generated SQL (read-only)
#   4. Ask the LLM to synthesize a natural language answer from the results
#
# Returns a hash with the same shape as BedrockRagService#query:
#   { answer: String, citations: Array, session_id: String|nil }
class SqlGenerationService
  # Custom error for SQL-related failures
  class SqlExecutionError < StandardError; end

  def initialize(query)
    @query = query
    @ai_provider = AiProvider.new
    # Connection is obtained from the isolated ClientDatabase abstract class,
    # ensuring it never interferes with the primary application database.
    @db_connection = ClientDatabase.connection
  end

  def execute
    schema = get_database_schema

    if schema.blank?
      Rails.logger.warn('SqlGenerationService: No tables found in client database.')
      return error_response('The client database appears to be empty.')
    end

    generated_sql = generate_sql(schema)
    Rails.logger.info("SqlGenerationService: Generated SQL: #{generated_sql}")

    results = execute_sql(generated_sql)
    answer = synthesize_answer(results)

    {
      answer: answer,
      citations: [],
      session_id: nil
    }
  rescue SqlExecutionError => e
    Rails.logger.error("SqlGenerationService SQL error: #{e.message}")
    error_response("I was unable to query the database. The generated SQL may have been invalid.")
  rescue StandardError => e
    Rails.logger.error("SqlGenerationService unexpected error: #{e.message}")
    Rails.logger.error(e.backtrace.first(5).join("\n"))
    error_response("I'm sorry, I was unable to retrieve an answer from the database.")
  end

  private

  # Reads the schema of all tables in the client database.
  # Returns a concise string representation the LLM can understand.
  def get_database_schema
    @db_connection.tables.map do |table|
      columns = @db_connection.columns(table).map do |col|
        "#{col.name} (#{col.type})"
      end
      "Table: #{table} | Columns: #{columns.join(', ')}"
    end.join("\n")
  end

  # Detects the database engine from the adapter to guide SQL dialect in the prompt.
  def database_engine
    adapter = @db_connection.adapter_name.downcase
    case adapter
    when /postgres/
      'PostgreSQL'
    when /mysql/
      'MySQL'
    when /sqlite/
      'SQLite'
    else
      adapter.capitalize
    end
  end

  # Asks the LLM to generate a SQL query based on the schema and user question.
  def generate_sql(schema)
    engine = database_engine

    sql_prompt = <<~PROMPT
      You are a SQL expert. The database engine is #{engine}. Given the database schema below, write a single, valid, read-only SQL query to answer the user's question.

      Rules:
      - Respond ONLY with the SQL code, no explanations or markdown.
      - Use only SELECT statements. Never use INSERT, UPDATE, DELETE, DROP, or ALTER.
      - Use table and column names exactly as shown in the schema.
      - Use only #{engine}-compatible functions and syntax (e.g., for PostgreSQL use STRING_AGG instead of GROUP_CONCAT).

      Schema:
      #{schema}

      Question: #{@query}
    PROMPT

    raw_response = @ai_provider.query(sql_prompt).to_s.strip

    # Clean up: remove markdown code fences and sql language tags if present
    raw_response
      .gsub(/```sql\s*/i, '')
      .gsub(/```\s*/, '')
      .strip
  end

  # Executes the generated SQL against the client database.
  # Uses exec_query which returns an ActiveRecord::Result (safer than raw execute).
  def execute_sql(sql)
    # Safety check: reject any non-SELECT statements
    unless sql.match?(/\A\s*SELECT/i)
      raise SqlExecutionError, "Generated SQL is not a SELECT statement: #{sql.truncate(200)}"
    end

    @db_connection.exec_query(sql)
  rescue ActiveRecord::StatementInvalid => e
    raise SqlExecutionError, "SQL execution failed: #{e.message}"
  end

  # Asks the LLM to convert raw query results into a natural language answer.
  def synthesize_answer(results)
    results_summary = if results.rows.empty?
                        'No results found.'
    else
                        results.to_a.first(50).to_json # Limit to 50 rows to avoid token overflow
    end

    synthesis_prompt = <<~PROMPT
      Based on the user's question and the database query results below, write a clear, natural language answer.
      Be concise and directly answer the question. If the results are empty, say so clearly.

      Question: #{@query}
      Database Results (JSON): #{results_summary}
    PROMPT

    @ai_provider.query(synthesis_prompt).to_s.strip
  end

  # Returns a standardized error response hash matching BedrockRagService shape.
  def error_response(message)
    {
      answer: message,
      citations: [],
      session_id: nil
    }
  end
end
