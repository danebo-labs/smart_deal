module DashboardHelper
  def format_model_name(model_id)
    case model_id
    when /haiku/i
      "Claude Haiku"
    when /sonnet/i
      "Claude Sonnet"
    when /opus/i
      "Claude Opus"
    when /titan/i
      "Amazon Titan"
    when /embed/i
      "Amazon Titan Embed"
    else
      model_id.split(".").first.capitalize
    end
  end
end
