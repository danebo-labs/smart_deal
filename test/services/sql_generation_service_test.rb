# frozen_string_literal: true

require 'test_helper'

class SqlGenerationServiceTest < ActiveSupport::TestCase
  # ============================================
  # Helpers
  # ============================================

  # Creates a mock AiProvider that returns controlled responses.
  # First call returns the SQL, second call returns the synthesis.
  def mock_ai_provider(sql_response:, synthesis_response: 'There are 5 records.')
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:query) do |_prompt, **_kwargs|
      call_count += 1
      call_count == 1 ? sql_response : synthesis_response
    end
    provider
  end

  # Stubs AiProvider.new to return our mock.
  def with_mock_ai_provider(mock_provider)
    original_new = AiProvider.method(:new)
    AiProvider.define_singleton_method(:new) { |**_kwargs| mock_provider }
    yield
  ensure
    AiProvider.define_singleton_method(:new) { |**kwargs| original_new.call(**kwargs) }
  end

  # Creates a mock DB connection with configurable tables, columns, and query results.
  def mock_db_connection(
    tables: [ 'products' ],
    columns: { 'products' => [ mock_column('id', :integer), mock_column('name', :string) ] },
    query_result: ActiveRecord::Result.new([ 'count' ], [ [ 5 ] ]),
    adapter_name: 'SQLite',
    should_raise: false
  )
    conn = Object.new

    conn.define_singleton_method(:tables) { tables }

    conn.define_singleton_method(:columns) do |table|
      columns[table] || []
    end

    conn.define_singleton_method(:adapter_name) { adapter_name }

    conn.define_singleton_method(:exec_query) do |_sql|
      raise ActiveRecord::StatementInvalid, 'Invalid SQL' if should_raise
      query_result
    end

    conn
  end

  # Creates a mock column object.
  def mock_column(name, type)
    col = Object.new
    col.define_singleton_method(:name) { name }
    col.define_singleton_method(:type) { type }
    col
  end

  # Stubs ClientDatabase.connection to return our mock connection.
  def with_mock_db_connection(mock_conn)
    original_connection = ClientDatabase.method(:connection)
    ClientDatabase.define_singleton_method(:connection) { mock_conn }
    yield
  ensure
    ClientDatabase.define_singleton_method(:connection) { original_connection.call }
  end

  # Combines AI provider and DB connection mocks.
  def with_full_mocks(sql_response:, synthesis_response: 'Answer.', db_conn: nil, **db_opts)
    provider = mock_ai_provider(sql_response: sql_response, synthesis_response: synthesis_response)
    conn = db_conn || mock_db_connection(**db_opts)
    with_mock_ai_provider(provider) do
      with_mock_db_connection(conn) do
        yield
      end
    end
  end

  # ============================================
  # Tests: Successful execution
  # ============================================

  test 'execute returns successful response with correct shape' do
    with_full_mocks(
      sql_response: 'SELECT COUNT(*) FROM products',
      synthesis_response: 'There are 5 products.'
    ) do
      result = SqlGenerationService.new('How many products?').execute

      assert result.is_a?(Hash)
      assert_equal 'There are 5 products.', result[:answer]
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'execute generates and runs SQL query' do
    executed_sql = nil
    conn = mock_db_connection
    # Override exec_query to capture the SQL
    conn.define_singleton_method(:exec_query) do |sql|
      executed_sql = sql
      ActiveRecord::Result.new([ 'count' ], [ [ 5 ] ])
    end

    with_full_mocks(sql_response: 'SELECT COUNT(*) FROM products', db_conn: conn) do
      SqlGenerationService.new('How many products?').execute
    end

    assert_equal 'SELECT COUNT(*) FROM products', executed_sql
  end

  # ============================================
  # Tests: SQL cleanup (markdown fences)
  # ============================================

  test 'strips markdown sql code fences from generated SQL' do
    executed_sql = nil
    conn = mock_db_connection
    conn.define_singleton_method(:exec_query) do |sql|
      executed_sql = sql
      ActiveRecord::Result.new([ 'count' ], [ [ 5 ] ])
    end

    with_full_mocks(
      sql_response: "```sql\nSELECT COUNT(*) FROM products\n```",
      db_conn: conn
    ) do
      SqlGenerationService.new('count products').execute
    end

    assert_equal 'SELECT COUNT(*) FROM products', executed_sql
  end

  test 'strips plain code fences from generated SQL' do
    executed_sql = nil
    conn = mock_db_connection
    conn.define_singleton_method(:exec_query) do |sql|
      executed_sql = sql
      ActiveRecord::Result.new([ 'count' ], [ [ 5 ] ])
    end

    with_full_mocks(
      sql_response: "```\nSELECT * FROM products\n```",
      db_conn: conn
    ) do
      SqlGenerationService.new('list products').execute
    end

    assert_equal 'SELECT * FROM products', executed_sql
  end

  # ============================================
  # Tests: Safety - reject non-SELECT
  # ============================================

  test 'rejects INSERT statements' do
    with_full_mocks(sql_response: "INSERT INTO products VALUES (1, 'test')") do
      result = SqlGenerationService.new('add a product').execute

      assert_includes result[:answer], 'unable to query the database'
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'rejects DELETE statements' do
    with_full_mocks(sql_response: 'DELETE FROM products WHERE id = 1') do
      result = SqlGenerationService.new('delete product 1').execute

      assert_includes result[:answer], 'unable to query the database'
    end
  end

  test 'rejects DROP statements' do
    with_full_mocks(sql_response: 'DROP TABLE products') do
      result = SqlGenerationService.new('drop the products table').execute

      assert_includes result[:answer], 'unable to query the database'
    end
  end

  test 'rejects UPDATE statements' do
    with_full_mocks(sql_response: "UPDATE products SET name = 'hacked'") do
      result = SqlGenerationService.new('update product names').execute

      assert_includes result[:answer], 'unable to query the database'
    end
  end

  # ============================================
  # Tests: Error handling
  # ============================================

  test 'handles SQL execution errors gracefully' do
    with_full_mocks(
      sql_response: 'SELECT * FROM nonexistent_table',
      should_raise: true
    ) do
      result = SqlGenerationService.new('query nonexistent').execute

      assert_includes result[:answer], 'unable to query the database'
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  test 'handles empty database gracefully' do
    with_full_mocks(
      sql_response: 'SELECT 1',
      tables: []
    ) do
      result = SqlGenerationService.new('anything').execute

      assert_includes result[:answer], 'database appears to be empty'
      assert_equal [], result[:citations]
      assert_nil result[:session_id]
    end
  end

  # ============================================
  # Tests: Schema reading
  # ============================================

  test 'reads database schema with table names and column types' do
    schema_captured = nil
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:query) do |prompt, **_kwargs|
      call_count += 1
      if call_count == 1
        schema_captured = prompt
        'SELECT COUNT(*) FROM orders'
      else
        'Answer.'
      end
    end

    columns = {
      'orders' => [ mock_column('id', :integer), mock_column('total', :decimal), mock_column('status', :string) ],
      'customers' => [ mock_column('id', :integer), mock_column('name', :string) ]
    }

    conn = mock_db_connection(
      tables: %w[orders customers],
      columns: columns
    )

    with_mock_ai_provider(provider) do
      with_mock_db_connection(conn) do
        SqlGenerationService.new('count orders').execute
      end
    end

    assert_includes schema_captured, 'Table: orders'
    assert_includes schema_captured, 'id (integer)'
    assert_includes schema_captured, 'total (decimal)'
    assert_includes schema_captured, 'status (string)'
    assert_includes schema_captured, 'Table: customers'
    assert_includes schema_captured, 'name (string)'
  end

  # ============================================
  # Tests: Database engine detection
  # ============================================

  test 'detects PostgreSQL adapter' do
    engine_captured = nil
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:query) do |prompt, **_kwargs|
      call_count += 1
      if call_count == 1
        engine_captured = prompt
        'SELECT 1'
      else
        'Answer.'
      end
    end

    conn = mock_db_connection(adapter_name: 'PostgreSQL')

    with_mock_ai_provider(provider) do
      with_mock_db_connection(conn) do
        SqlGenerationService.new('test').execute
      end
    end

    assert_includes engine_captured, 'The database engine is PostgreSQL'
  end

  test 'detects SQLite adapter' do
    engine_captured = nil
    call_count = 0
    provider = Object.new
    provider.define_singleton_method(:query) do |prompt, **_kwargs|
      call_count += 1
      if call_count == 1
        engine_captured = prompt
        'SELECT 1'
      else
        'Answer.'
      end
    end

    conn = mock_db_connection(adapter_name: 'SQLite')

    with_mock_ai_provider(provider) do
      with_mock_db_connection(conn) do
        SqlGenerationService.new('test').execute
      end
    end

    assert_includes engine_captured, 'The database engine is SQLite'
  end

  # ============================================
  # Tests: Response normalization
  # ============================================

  test 'successful response always has citations as empty array' do
    with_full_mocks(sql_response: 'SELECT 1', synthesis_response: 'Done.') do
      result = SqlGenerationService.new('test').execute

      assert_instance_of Array, result[:citations]
      assert_empty result[:citations]
    end
  end

  test 'successful response always has session_id as nil' do
    with_full_mocks(sql_response: 'SELECT 1', synthesis_response: 'Done.') do
      result = SqlGenerationService.new('test').execute

      assert_nil result[:session_id]
    end
  end

  test 'error response maintains correct shape' do
    with_full_mocks(sql_response: 'DROP TABLE x') do
      result = SqlGenerationService.new('bad query').execute

      assert result.is_a?(Hash)
      assert result.key?(:answer)
      assert result.key?(:citations)
      assert result.key?(:session_id)
      assert_instance_of Array, result[:citations]
      assert_nil result[:session_id]
    end
  end

  # ============================================
  # Tests: SqlExecutionError custom error
  # ============================================

  test 'SqlExecutionError is a StandardError subclass' do
    assert SqlGenerationService::SqlExecutionError < StandardError
  end
end
