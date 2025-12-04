namespace :metrics do
  desc "Create sample BedrockQuery for testing"
  task :create_sample_query, [:model_id, :input_tokens, :output_tokens] => :environment do |_t, args|
    model_id = args[:model_id] || "anthropic.claude-3-5-sonnet-20241022-v2:0"
    input_tokens = (args[:input_tokens] || 100).to_i
    output_tokens = (args[:output_tokens] || 50).to_i
    
    query = BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: "Sample query for testing",
      created_at: Time.current
    )
    
    puts "✓ Created BedrockQuery:"
    puts "  ID: #{query.id}"
    puts "  Model: #{query.model_id}"
    puts "  Input tokens: #{query.input_tokens}"
    puts "  Output tokens: #{query.output_tokens}"
    puts "  Cost: $#{query.cost}"
    puts "  Created at: #{query.created_at}"
  end

  desc "Collect metrics for last month (all days)"
  task collect_last_month: :environment do
    last_month_start = 1.month.ago.beginning_of_month
    last_month_end = 1.month.ago.end_of_month
    
    puts "Collecting metrics from #{last_month_start} to #{last_month_end}"
    
    (last_month_start..last_month_end).each do |date|
      puts "Processing #{date}..."
      begin
        SimpleMetricsService.new(date).save_daily_metrics
        puts "  ✓ Metrics saved for #{date}"
      rescue => e
        puts "  ✗ Error for #{date}: #{e.message}"
      end
    end
    
    puts "Done! Collected metrics for last month."
  end

  desc "Collect metrics for a specific date (defaults to today)"
  task :collect, [:date] => :environment do |_t, args|
    date = args[:date] ? Date.parse(args[:date]) : Date.current
    puts "Collecting metrics for #{date}..."
    
    begin
      SimpleMetricsService.new(date).save_daily_metrics
      puts "✓ Metrics saved for #{date}"
    rescue => e
      puts "✗ Error: #{e.message}"
      raise
    end
  end

  desc "Collect metrics for a date range"
  task :collect_range, [:start_date, :end_date] => :environment do |_t, args|
    start_date = Date.parse(args[:start_date])
    end_date = Date.parse(args[:end_date])
    
    puts "Collecting metrics from #{start_date} to #{end_date}"
    
    (start_date..end_date).each do |date|
      puts "Processing #{date}..."
      begin
        SimpleMetricsService.new(date).save_daily_metrics
        puts "  ✓ Metrics saved for #{date}"
      rescue => e
        puts "  ✗ Error for #{date}: #{e.message}"
      end
    end
    
    puts "Done! Collected metrics for the specified range."
  end
end

