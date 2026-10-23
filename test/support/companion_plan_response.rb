# frozen_string_literal: true

# Converse response shape for a forced companion_plan tool call.
module CompanionPlanResponse
  ToolUse = Struct.new(:name, :input, :tool_use_id)
  Block = Struct.new(:tool_use, :text)
  Message = Struct.new(:content, :role)
  Output = Struct.new(:message)
  Usage = Struct.new(:input_tokens, :output_tokens, :total_tokens)
  Response = Struct.new(:output, :stop_reason, :usage)

  def self.build(input, stop_reason: "tool_use", input_tokens: 1000, output_tokens: 100)
    block = Block.new(ToolUse.new(Rag::CompanionPlan::TOOL_NAME, input, "tool-1"), nil)
    Response.new(
      Output.new(Message.new([ block ], "assistant")),
      stop_reason,
      Usage.new(input_tokens, output_tokens, input_tokens + output_tokens)
    )
  end
end
