require "test_helper"

class RagControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
  end

  test "requires authentication" do
    post rag_ask_url, params: { question: "test question" }, as: :json
    # Devise returns 401 for JSON requests instead of redirect
    assert_response :unauthorized
    json = JSON.parse(@response.body)
    assert json.key?("error")
  end

  test "rejects empty question" do
    sign_in @user
    post rag_ask_url, params: { question: "" }, as: :json
    assert_response :bad_request
    
    json = JSON.parse(@response.body)
    assert_equal "error", json["status"]
    assert_includes json["message"].downcase, "empty"
  end

  test "rejects blank question" do
    sign_in @user
    post rag_ask_url, params: { question: "   " }, as: :json
    assert_response :bad_request
    
    json = JSON.parse(@response.body)
    assert_equal "error", json["status"]
  end

  test "returns successful response with answer and citations" do
    sign_in @user
    
    # Create a mock service object with query method
    mock_service = Object.new
    def mock_service.query(question)
      {
        answer: "This is a test answer about S3",
        citations: [
          {
            file_name: "AWS-Certified-Solutions-Architect-v4.pdf",
            uri: "s3://bucket/file.pdf",
            content: "S3 is a storage service..."
          }
        ],
        session_id: "test-session-123"
      }
    end
    
    # Monkey patch BedrockRagService.new temporarily
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*args| mock_service }
    
    begin
      post rag_ask_url, params: { question: "What is S3?" }, as: :json
      assert_response :success
      
      json = JSON.parse(@response.body)
      assert_equal "success", json["status"]
      assert_equal "This is a test answer about S3", json["answer"]
      assert_equal "test-session-123", json["session_id"]
      assert json.key?("citations")
      assert_equal 1, json["citations"].length
      assert_equal "AWS-Certified-Solutions-Architect-v4.pdf", json["citations"].first["file_name"]
    ensure
      # Restore original method
      BedrockRagService.define_singleton_method(:new, original_new)
    end
  end

  test "handles BedrockRagService errors gracefully" do
    sign_in @user
    
    # Create a mock service that raises an error
    mock_service = Object.new
    def mock_service.query(question)
      raise StandardError.new("Knowledge Base ID not configured")
    end
    
    # Monkey patch BedrockRagService.new temporarily
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*args| mock_service }
    
    begin
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :unprocessable_entity
      
      json = JSON.parse(@response.body)
      assert_equal "error", json["status"]
      assert json["message"].present?
      assert_includes json["message"], "Error processing question"
    ensure
      # Restore original method
      BedrockRagService.define_singleton_method(:new, original_new)
    end
  end

  test "handles AWS service errors" do
    sign_in @user
    
    # Create a mock service that raises an AWS error
    mock_service = Object.new
    def mock_service.query(question)
      raise StandardError.new("AccessDeniedException: User is not authorized")
    end
    
    # Monkey patch BedrockRagService.new temporarily
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*args| mock_service }
    
    begin
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :unprocessable_entity
      
      json = JSON.parse(@response.body)
      assert_equal "error", json["status"]
      assert json["message"].present?
    ensure
      # Restore original method
      BedrockRagService.define_singleton_method(:new, original_new)
    end
  end

  test "handles response without citations" do
    sign_in @user
    
    # Create a mock service with empty citations
    mock_service = Object.new
    def mock_service.query(question)
      {
        answer: "Answer without citations",
        citations: [],
        session_id: "test-session-456"
      }
    end
    
    # Monkey patch BedrockRagService.new temporarily
    original_new = BedrockRagService.method(:new)
    BedrockRagService.define_singleton_method(:new) { |*args| mock_service }
    
    begin
      post rag_ask_url, params: { question: "test question" }, as: :json
      assert_response :success
      
      json = JSON.parse(@response.body)
      assert_equal "success", json["status"]
      assert_equal "Answer without citations", json["answer"]
      assert_equal [], json["citations"]
    ensure
      # Restore original method
      BedrockRagService.define_singleton_method(:new, original_new)
    end
  end
end

