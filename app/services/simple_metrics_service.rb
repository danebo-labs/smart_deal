class SimpleMetricsService
    def initialize(date = Date.current)
      @date = date
      @cloudwatch = Aws::CloudWatch::Client.new(region: "us-east-1")
      @s3 = Aws::S3::Client.new(region: "us-east-1")
    end
  
    def save_daily_metrics
      metrics = collect_daily_metrics
  
      metrics.each do |metric_type, value|
        CostMetric.find_or_initialize_by(date: @date, metric_type: metric_type).tap do |m|
          m.value = value
          m.save!
        end
      end
    end
  
    def collect_daily_metrics
      {
        daily_tokens: calculate_daily_tokens,
        daily_cost: calculate_daily_cost,
        daily_queries: calculate_daily_queries,
        aurora_acu_avg: get_aurora_acu_average,
        s3_documents_count: get_s3_document_count,
        s3_total_size: get_s3_total_size
      }
    end
  
    private
  
    #
    # METRICS FROM DATABASE
    #
  
    def calculate_daily_tokens
      BedrockQuery.where(created_at: @date.all_day)
                  .sum("input_tokens + output_tokens")
    end
  
    def calculate_daily_cost
      BedrockQuery.where(created_at: @date.all_day)
                  .sum { |query| query.cost }
    end
  
    def calculate_daily_queries
      BedrockQuery.where(created_at: @date.all_day).count
    end
  
    #
    # METRICS FROM CLOUDWATCH
    #
  
    def get_aurora_acu_average
      begin
        resp = @cloudwatch.get_metric_statistics(
          namespace: "AWS/RDS",
          metric_name: "ServerlessDatabaseCapacity",
          dimensions: [
            { name: "DBClusterIdentifier", value: "knowledgebasequickcreateaurora-407-auroradbcluster-bb0lvonokgdy" }
          ],
          start_time: @date.beginning_of_day,
          end_time: @date.end_of_day,
          period: 3600,
          statistics: ["Average"]
        )
  
        return 0 if resp.datapoints.empty?
  
        averages = resp.datapoints.map(&:average)
        averages.sum / averages.count
      rescue => e
        Rails.logger.error("Error fetching Aurora ACU metrics: #{e.message}")
        0
      end
    end
  
    #
    # S3 METRICS
    #
  
    def get_s3_document_count
      bucket = ENV["KNOWLEDGE_BASE_S3_BUCKET"] || "your-kb-bucket"
  
      begin
        resp = @s3.list_objects_v2(bucket: bucket)
        resp.contents.count
      rescue
        0
      end
    end
  
    def get_s3_total_size
      bucket = ENV["KNOWLEDGE_BASE_S3_BUCKET"] || "your-kb-bucket"
  
      begin
        resp = @s3.list_objects_v2(bucket: bucket)
        resp.contents.sum(&:size)
      rescue
        0
      end
    end
  end
  