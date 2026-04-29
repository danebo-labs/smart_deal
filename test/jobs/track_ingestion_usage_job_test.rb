# frozen_string_literal: true

require "test_helper"

class TrackIngestionUsageJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  SAMPLE_FILENAME = "manual_orona.txt"

  setup do
    BedrockQuery.destroy_all
    CostMetric.destroy_all
  end

  # Stub S3 to return text content
  def with_fake_s3(content: "elevator technical doc " * 100)
    fake_body = StringIO.new(content)
    fake_resp = Struct.new(:body).new(fake_body)
    fake_client = Object.new
    fake_client.define_singleton_method(:get_object) { |**_| fake_resp }

    original_new = Aws::S3::Client.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_| fake_client }
    yield
  ensure
    Aws::S3::Client.define_singleton_method(:new) { |*args, **opts| original_new.call(*args, **opts) }
  end

  def with_turbo_stubbed
    orig = Turbo::StreamsChannel.method(:broadcast_update_to)
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*a, **k| nil }
    yield
  ensure
    Turbo::StreamsChannel.define_singleton_method(:broadcast_update_to) { |*a, **k| orig.call(*a, **k) }
  end

  test "creates 2 BedrockQuery records per file (parse + embed)" do
    with_fake_s3 do
      with_turbo_stubbed do
        assert_difference "BedrockQuery.count", 2 do
          TrackIngestionUsageJob.perform_now(uploaded_filenames: [ SAMPLE_FILENAME ])
        end
      end
    end

    parse_rec = BedrockQuery.find_by(source: "ingestion_parse")
    embed_rec = BedrockQuery.find_by(source: "ingestion_embed")

    assert parse_rec, "ingestion_parse record must be created"
    assert embed_rec, "ingestion_embed record must be created"
    assert_equal "global.anthropic.claude-opus-4-6-v1", parse_rec.model_id
    assert_equal "amazon.nova-2-multimodal-embeddings-v1:0", embed_rec.model_id
    assert parse_rec.input_tokens > 0
    assert_equal 0, embed_rec.output_tokens
    assert_includes parse_rec.user_query, "[parse]"
    assert_includes embed_rec.user_query, "[embed]"
  end

  test "processes multiple files independently" do
    with_fake_s3 do
      with_turbo_stubbed do
        assert_difference "BedrockQuery.count", 4 do
          TrackIngestionUsageJob.perform_now(uploaded_filenames: [ "doc1.txt", "doc2.txt" ])
        end
      end
    end
  end

  test "skips file if already tracked within idempotency window" do
    label = "[parse] #{SAMPLE_FILENAME}".truncate(500)
    BedrockQuery.create!(
      model_id: "global.anthropic.claude-opus-4-6-v1",
      input_tokens: 100, output_tokens: 10,
      user_query: label, latency_ms: 0, source: :ingestion_parse
    )

    with_fake_s3 do
      with_turbo_stubbed do
        assert_no_difference "BedrockQuery.count" do
          TrackIngestionUsageJob.perform_now(uploaded_filenames: [ SAMPLE_FILENAME ])
        end
      end
    end
  end

  test "skips gracefully when S3 key not found" do
    fake_client = Object.new
    fake_client.define_singleton_method(:get_object) do |**_|
      raise Aws::S3::Errors::NoSuchKey.new(nil, "Not found")
    end
    orig = Aws::S3::Client.method(:new)
    Aws::S3::Client.define_singleton_method(:new) { |*_| fake_client }

    with_turbo_stubbed do
      assert_no_difference "BedrockQuery.count" do
        assert_nothing_raised do
          TrackIngestionUsageJob.perform_now(uploaded_filenames: [ SAMPLE_FILENAME ])
        end
      end
    end
  ensure
    Aws::S3::Client.define_singleton_method(:new) { |*args, **opts| orig.call(*args, **opts) }
  end
end
