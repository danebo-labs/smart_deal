# frozen_string_literal: true

# Fase 1 (docs/EJECUCION_PRE_DEMO_2026-09-10.md). Read-only: 2 retrieve_and_generate.
# Mide el desfase real de citation.generated_response_part.text_response_part.span
# contra el texto sobre el que add_span_citations inserta los marcadores.
PROBE = {}
Aws::BedrockAgentRuntime::Client.prepend(Module.new do
  def retrieve_and_generate(*args)
    super.tap { |r| PROBE[:raw] = r.output.text }
  end
end)
Bedrock::CitationProcessor.prepend(Module.new do
  def add_span_citations(text, raw_citations)
    PROBE[:spans] = [ text.dup, raw_citations ]
    super
  end
end)

account = Account.find(Integer(ENV.fetch("PILOT_BATTERY_ACCOUNT_ID", "3")))
{ 6 => "¿Qué hace la tarjeta LCE y dónde está su configuración?",
  8 => "¿Cómo se parametriza el variador en un Yida y qué valores trae por defecto?" }.each do |n, question|
  PROBE.clear
  BedrockRagService.new(account: account).query(question, output_channel: :web)
  puts "=== Q#{n} #{question}"
  puts "RAW_OUTPUT_TEXT<<#{PROBE[:raw]}>>"
  text, raw_citations = PROBE[:spans]
  next puts "  add_span_citations NO se invocó (canned/sin citas/ya numerado)" unless text
  puts "  base_eq_raw=#{text == PROBE[:raw]} chars=#{text.length} bytes=#{text.bytesize} groups=#{Array(raw_citations).size}"
  Array(raw_citations).each_with_index do |citation, j|
    span = citation.generated_response_part&.text_response_part&.span
    next puts "  cit#{j}: sin span" unless span
    s, e = span.start, span.end
    lo = [ e - 3, 0 ].max
    puts "  cit#{j} start=#{s} end=#{e} at_end=#{text[e].inspect} win=#{text[lo..(e + 3)].inspect} " \
         "bytewin=#{text.byteslice(lo, 7).inspect} tail_incl=#{text[[ s, e - 20 ].max..e].inspect}"
  end
end
