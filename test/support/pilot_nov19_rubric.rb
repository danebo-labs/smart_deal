# frozen_string_literal: true

# Assertions for the facts at issue in the November 19 pilot. The patterns
# describe predicates and polarity, so they can be checked independently of
# sentence order. Citations and persisted data are checked by the caller.
module PilotNov19Rubric
  FIRST_OPERATION = /\bprimer(?:[ao]s?)?\s+(?:operaci\w*|maniobr\w*|apertur\w*|ciclo\w*)|\bprimera vez/
  POWER_LOSS = /\b(?:corte|fall[oa]|perdida|interrupcion|perder)\b|(?:perdio|volvio) la corriente/
  ELECTRICAL_SUPPLY = /\b(?:alimentacion|corriente|electricidad|energia|suministro|tension|luz)\b/
  SLOW = /\blent\w*|\bdespacio\b|\bbaja velocidad\b/
  ADJUSTMENT = /\bauto\s*ajust\w*|\b(?:ajuste|calibracion) automatic[oa]\b/
  UNNECESSARY = /\b(?:innecesari\w*|prescindible\w*)|\b(?:no|sin)\b[^.!?]{0,35}\b(?:hace falta|haya? que|necesari\w*|requier\w*|amerit\w*|necesit\w*|repetir)/
  DEFAULTS = /\b(?:defecto|predeterminad\w*|fabrica)\b/
  PHOTOCELL = /\bfotocelul\w*|\bcelula fotoelectric\w*/
  CONNECT = /\b(?:conec\w*|reconec\w*|enchuf\w*|instal\w*)/
  DISCONNECT = /\b(?:desconec\w*|desenchuf\w*|desinstal\w*|retir\w*)/
  FAN = /\b(?:ventilador|abanico)\b/
  ROTATION = /\b(?:gir\w*|rot\w*|funcion\w*|march\w*)\b/
  TEMPERATURE = /(?<![\d.,])26(?:[.,]0+)?\s*(?:[°º]\s*c|grados\s+(?:centigrados|celsius))(?![[:alnum:]])/
  DOC_LIMIT = /\b(?:limite|umbral|criterio|referencia)\b/
  UNDOCUMENTED = /\b(?:carece|falta|sin|ningun\w*)\b|\bno\b[^.!?]{0,45}\b(?:aparece|cuenta|document\w*|da|hay|indic\w*|permit\w*|public\w*|tien\w*|pued\w*|registr\w*|especific\w*)\b/
  FILTER_CLEAN = /\b(?:limpi\w*|ase\w*)\b/
  ERROR_PERSISTS = /\b(?:persis\w*|sigue|continua|permanece|mantiene)\b/
  ERROR_CLEARED = /\b(?:ya no|dejo de|no (?:se )?(?:persis\w*|sigue|continua|permanece))\b/
  STOP_INTERLOCK = /\b(?:enclavam\w*|cerroj\w*)\b/
  APPLICABILITY_PENDING = /\b(?:por confirmar|pendiente\w*|falta\s+(?:confirm\w*|verific\w*)|sin\s+(?:confirm\w*|verific\w*)|no\s+(?:se\s+)?(?:ha\s+)?(?:confirm\w*|verific\w*))\b/
  SOURCE_REFERENCE = /\b(?:fuente|manual|referencia|document\w*)\b/
  PLATE = /\b(?:placa|modelo|controlador|instalacion|equipo)\b/
  RETRACTED = /\b(?:retrai\w*|retra\w*|retirad\w*|recogid\w*)\b/
  NOT_RETRACTED = /\bno\b[^,;.!?]{0,18}\b(?:retrai\w*|retra\w*|retirad\w*|recogid\w*)\b/
  CONDITION = /\b(?:si|cuando|solo|siempre que|mientras|en caso)\b/
  ENERGIZED = /\b(?:encend\w*|activ\w*|ilumin\w*|energiz\w*)\b/
  STAYED = /\b(?:estable\w*|permanec\w*|mantu\w*|sostuv\w*|continu\w*|qued\w*|sigu\w*|sigue)\b/
  ABSENT_FAULT = /\b(?:sin|ausen\w*)\b|\bno\b[^.!?]{0,45}\b(?:aparec\w*|reaparec\w*|mostr\w*|muestr\w*|present\w*|registr\w*|detect\w*|volv\w*)\b/
  TEST_SCOPE = /\b(?:prueba|ensayo|maniobra|ciclo)\b/
  CAUSE_OPEN = /\b(?:hipotesis|por confirmar|sin confirmar|indeterminad\w*)\b|\bno\b[^.!?]{0,55}\b(?:confirma|prueba|establece|demuestra|permite)\b/
  DONE = /\b(?:complet\w*|termin\w*|finaliz\w*|conclu\w*)\b/
  ACTED = /\b(?:actu\w*|accion\w*|funcion\w*|activ\w*)\b/
  NEGATED_OUTCOME = /\b(?:no|sin)\b[^,;.!?]{0,16}\b(?:complet\w*|termin\w*|actu\w*|accion\w*|encend\w*|ilumin\w*|activ\w*)\b/
  FOREIGN_FIELD = {
    "pt" => /\b(?:engate|disjuntor|quando falha|porta aberta|linha dos trincos|verifique a|nao voltou|sinal de porta)\b/,
    "en" => /\b(?:the door|the fan|the display|does the|check whether|was (?:dcl|dfc|not verified)|according to the manual)\b/
  }.freeze

  module_function

  def normalize(text)
    text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase
  end

  def claim?(text, *predicates, without: nil)
    Rag::CompanionTurnPublication.claim_fragments(text).any? do |fragment|
      normalized = normalize(fragment)
      predicates.all? { |pattern| normalized.match?(pattern) } && (!without || !normalized.match?(without))
    end
  end

  def field_text(text)
    text.to_s.gsub(Rag::CompanionTurnPublication::QUOTE_PATTERN, " ")
  end

  # Audits the foreign terms and orientation forms present in the pilot
  # evidence and in its bilingual controls. A literal quotation is exempt.
  def language_findings(text)
    field_text(text).split(/(?<=[.!?？])\s+|\n+/).filter_map do |fragment|
      language = FOREIGN_FIELD.find { |_code, pattern| normalize(fragment).match?(pattern) }&.first
      next unless language

      field = fragment.match?(/[¿?？]/) ? "question" : "orientation"
      "#{field}:#{language}"
    end.uniq
  end
end
