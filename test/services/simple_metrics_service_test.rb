require "test_helper"

class SimpleMetricsServiceTest < ActiveSupport::TestCase
  class FakeCloudWatch
    def initialize(*); end

    def get_metric_statistics(*)
      OpenStruct.new(datapoints: [])
    end
  end

  class FakeS3
    def initialize(*); end

    def list_objects_v2(*)
      OpenStruct.new(contents: [])
    end
  end

  test "collect_daily_metrics returns all keys" do
    # Create mock AWS modules and classes
    aws_module = Module.new
    cloudwatch_module = Module.new
    s3_module = Module.new

    cloudwatch_module.const_set(:Client, FakeCloudWatch)
    s3_module.const_set(:Client, FakeS3)
    aws_module.const_set(:CloudWatch, cloudwatch_module)
    aws_module.const_set(:S3, s3_module)

    # Temporarily replace Aws constant to use our mocks
    original_aws = Object.const_get(:Aws) if Object.const_defined?(:Aws)
    Object.send(:remove_const, :Aws) if Object.const_defined?(:Aws)
    Object.const_set(:Aws, aws_module)

    begin
      service = SimpleMetricsService.new(Date.today)

      metrics = service.collect_daily_metrics

      expected_keys = [
        :daily_tokens,
        :daily_cost,
        :daily_queries,
        :aurora_acu_avg,
        :s3_documents_count,
        :s3_total_size
      ]

      assert_equal expected_keys.sort, metrics.keys.sort
    ensure
      # Restore original Aws constant
      Object.send(:remove_const, :Aws)
      Object.const_set(:Aws, original_aws) if original_aws
    end
  end
end
