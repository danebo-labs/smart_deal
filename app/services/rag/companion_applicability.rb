# frozen_string_literal: true

module Rag
  # A literal quote certifies what the document says, not the case inference.
  # Reject specific unsupported transfers while preserving independent advice.
  module CompanionApplicability
    NON_DIAGNOSTIC = /\b(?:subdimension\w*|dimensionamiento|derating|vida [uú]til|condiciones? base|almacenamiento|nominal)\b/i
    LIMIT = /(?:\d+[.,]?\d*\s*°\s*[CF]|\bumbral\b|\bl[ií]mite\b)/i
    DIAGNOSTIC_INFERENCE = /(?:menos probable|m[aá]s probable|no parece (?:ser )?la causa|dentro del rango de operaci[oó]n|por debajo del l[ií]mite|descart\w*|exclu\w*|reduce (?:el riesgo|la probabilidad))/i
    RESULT = /\b(?:encendid[oa]|apagad[oa]|parpade\w*|fij[oa])\b/i
    LED_KIND = /\bLED (?:de (?:la )?)?(?:fotoc[eé]lula|obstrucci[oó]n|status|estado|re-?apertura)\b/i
    LED_INFERENCE = /(?:lo que queda por revisar|la hip[oó]tesis que queda|la (?:[uú]nica|principal) hip[oó]tesis)/i
    PERSISTENCE_DECISION = /\b(?:(?:condici[oó]n|persistencia) (?:a[uú]n |todav[ií]a )?(?:no se cumple|no se ha cumplido|ya se cumple|se cumple)|(?:no |ya )?se cumple (?:esa|esta|la) condici[oó]n)\b/i
    MODE = /\b(?:SW|DIP)\s*\d+\b/i
    Result = Data.define(:text, :removed)

    module_function

    def check(text:, sources:, technician_texts:)
      fragments = CompanionTurnPublication.claim_fragments(text)
      evidence = technician_texts.map(&:to_s)
      unlabelled = evidence.any? { |line| line.match?(/\bLED\b/i) && line.match?(RESULT) } &&
        evidence.none? { |line| line.downcase.match?(LED_KIND) && line.match?(RESULT) }
      inactive = evidence.any? { |line| line.match?(/fotoc[eé]lula[^.!?]{0,50}\b(?:no (?:est[aá]|se (?:ha )?activ)|inactiva)/i) }
      persistence_reported = evidence.any? { |line| line.match?(/\b(?:sigue|persiste|volvi[oó]|dej[oó] de|ya no)\s+(?:el problema|la falla|re-?abri[eé]ndose|a re-?abrirse|re-?abri[rse]+)/i) }
      sizing_reference = false
      removed = []
      fragments.each do |fragment|
        cited_threshold = non_diagnostic_threshold?(fragment, sources)
        reason = if fragment.match?(DIAGNOSTIC_INFERENCE) && (cited_threshold ||
            (sizing_reference && fragment.match?(/temperatur|umbral|l[ií]mite|medici[oó]n|ambiente/i)))
          "threshold_purpose"
        elsif unlabelled && !fragment.match?(/[¿?]/) &&
            (fragment.match?(LED_INFERENCE) || fragment.match?(/fuente asocia el LED (?:encendido|apagado)/i) ||
              (fragment.downcase.match?(LED_KIND) && fragment.match?(RESULT) && !fragment.match?(/(?:[«“"]|\bsi\s+(?:es|fuera|resulta|se)\b)/i)))
          "led_referent_unconfirmed"
        elsif !persistence_reported && fragment.match?(PERSISTENCE_DECISION)
          "persistence_unconfirmed"
        elsif inactive && fragment.match?(MODE) && fragment.match?(/(?:lo que (?:falta|respalda)|posici[oó]n|activaci[oó]n de la fotoc[eé]lula)/i)
          "mode_condition_inactive"
        end
        sizing_reference = cited_threshold
        removed << { "sentence" => fragment, "reason" => reason } if reason
      end
      return Result.new(text, []) if removed.empty?

      body = text.dup
      removed.each do |row|
        fragment = row.fetch("sentence")
        body.sub!(/#{Regexp.escape(fragment)}[.!?]*/, "")
      end
      body.gsub!(/^[ \t]*[.!?]+[ \t]*$/, "")
      notes = removed.pluck("reason")
      body += "\n\nTenemos el estado observado del LED; todavía falta identificar qué indicador es." if notes.include?("led_referent_unconfirmed")
      body += "\n\nNo está comprobado si el problema persiste." if notes.include?("persistence_unconfirmed")
      body += "\n\nEse umbral no permite priorizar ni descartar una causa; falta un criterio de diagnóstico para esa medición." if notes.include?("threshold_purpose")
      Result.new(body.strip, removed)
    end

    def non_diagnostic_threshold?(fragment, sources)
      return false unless fragment.match?(LIMIT)

      fragment.scan(CompanionTurnPublication::CITATION_PATTERN).flatten.map(&:to_i).any? do |number|
        content = sources[number - 1]&.fetch("content", "").to_s
        fragment.scan(CompanionTurnPublication::QUOTE_PATTERN).any? do |parts|
          quote = parts.compact.first.to_s
          offset = content.index(quote)
          quote.match?(NON_DIAGNOSTIC) || (offset && content[[ offset - 100, 0 ].max, quote.length + 170].match?(NON_DIAGNOSTIC))
        end
      end
    end
  end
end
