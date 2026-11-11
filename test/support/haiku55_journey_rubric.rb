# frozen_string_literal: true

require Rails.root.join("test/support/companion_vertical_ladder").to_s

# The behavioral rubric of the three journeys. The offline replay and the
# live HTTP runner read the same reasons. An empty list is a pass.
module Haiku55JourneyRubric
  # G1-T5: the technician cannot check #21 nor the 21–23 contact. The answer
  # names that limit, of the technician or of the documents, and does not
  # send him back to the same contact as a visual inspection.
  T5_LIMIT = /
    no[[:space:]]+(?:puedes|sabes)[[:space:]]+(?:identificar|comprobar|verificar|saber)
    |no[[:space:]]+te[[:space:]]+(?:pido|vuelvo[[:space:]]+a[[:space:]]+pedir)[[:space:]]+(?:que[[:space:]]+)?(?:identific|comprob|verific)
    |no[[:space:]]+te[[:space:]]+lo[[:space:]]+(?:pido|pedir[eé]|voy[[:space:]]+a[[:space:]]+pedir)
    |no[[:space:]]+puedo[[:space:]]+darte[[:space:]]+(?:ese[[:space:]]+paso|un[[:space:]]+m[eé]todo|otra[[:space:]]+forma)
  /ix
  T5_REASKS_CONTACT = /
    confirmar[[:space:]]+si[[:space:]]+hay[[:space:]]+un[[:space:]]+contacto
    |conexi[oó]n[[:space:]]+f[ií]sica[[:space:]]+entre
    |(?:mira|mirar|revisa|revisar|f[ií]jate|observa|observar)[^.\n]{0,40}(?:algo|cable|puente)[^.\n]{0,30}conectad
  /ix

  # Variants change the history a correction depends on. Turns that keep the
  # journey's text keep its rubric; the changed turns get the opposite check.
  VARIANT_TURNS = {
    "guion1_photocell_active" => { "base" => "guion1", "changed" => [ 3, 4 ] },
    "guion1_can_measure" => { "base" => "guion1", "changed" => [ 5 ] }
  }.freeze
  TECHNICIAN_UNABLE = /
    no[[:space:]]+(?:puedes|sabes)[[:space:]]+(?:identificar|comprobar|verificar|medir)
    |no[[:space:]]+te[[:space:]]+(?:pido|vuelvo[[:space:]]+a[[:space:]]+pedir)
  /ix

  module_function

  def variant_reasons(name, number, answer, questions)
    spec = VARIANT_TURNS.fetch(name)
    return reasons(spec["base"], number, answer, questions) unless spec["changed"].include?(number)

    case [ name, number ]
    when [ "guion1_photocell_active", 4 ]
      missing = []
      missing << "variant:photocell_discarded" if answer.match?(/fotoc[eé]lula[^.\n]{0,40}(?:no[[:space:]]+(?:est[aá][[:space:]]+)?activad|descartad)/i) ||
        answer.match?(/fotoc[eé]lula[[:space:]]+(?:est[aá][[:space:]]+)?libre/i)
      missing << "variant:photocell_dropped" unless answer.match?(/fotoc[eé]lula/i)
      missing
    when [ "guion1_can_measure", 5 ]
      missing = []
      engaged = answer.match?(/#?21\b/) && answer.match?(/#?23\b/) && answer.match?(/conectar|puente|tensi[oó]n|continuidad|12[[:space:]]*V/i)
      missing << "variant:contact_not_engaged" unless engaged
      missing << "variant:treated_as_unable" if answer.match?(TECHNICIAN_UNABLE)
      missing
    else
      []
    end
  end

  def reasons(name, number, answer, questions)
    return variant_reasons(name, number, answer, questions) if VARIANT_TURNS.key?(name)

    judge = Rag::CompanionVerticalLadder.allocate
    reasons = case name
    when "guion2" then judge.send(:judge_guion2, number, answer)
    when "guion1" then judge.send(:judge_guion1, number, answer, technician_texts: questions.first(number))
    when /\Acea/ then cea_reasons(number, answer)
    else []
    end
    slow = Rag::CompanionVerticalLadder::SLOW
    prefix = slow.split(" para verificar", 2).first
    if prefix && slow.start_with?(prefix) && answer.include?(prefix)
      reasons -= %w[t1:missing_slow_opening t2:unused_first_opening t3:missing_section]
    end
    if name == "guion1" && number == 4
      reasons << "t4:dip4" if answer.match?(/DIP\s*4/i)
    end
    if name == "guion1" && number == 5
      reading = judge.send(:t5_assessment, answer, technician_texts: questions.first(number))
      reasons << "t5:reasks_contact" if answer.match?(T5_REASKS_CONTACT)
      reasons << "t5:reasks_identification" if reading.dig("identification_request", "present")
      reasons.delete("t5:misses_unknown")
      limited = reading.dig("technician_limitation", "recognized") || reading.dig("method_limit", "present") ||
        answer.match?(T5_LIMIT)
      reasons << "t5:limit_not_acknowledged" unless limited
    end
    reasons.concat(elemont_reasons(number, answer)) if name == "elemont"
    reasons
  end

  # CEA15+ with the plate still pending: the label is asked once, in T1.
  def cea_reasons(number, answer)
    asked = I18n.available_locales.any? { |code| answer.include?(I18n.t("rag.controller_label_question", locale: code)) }
    reasons = []
    reasons << "cea:label_not_asked" if number == 1 && !asked
    reasons << "cea:label_reasked" if number > 1 && asked
    reasons << "cea:service_unavailable" if answer.match?(/servicio no est[aá] disponible/i)
    reasons << "cea:no_evidence" if answer.start_with?(I18n.t("rag.focus_evidence_insufficient", locale: :es))
    reasons << "cea:withheld" if answer.start_with?(I18n.t("rag.unconfirmed_reference_withheld", locale: :es, references: "|").split("|").first.strip)
    reasons.concat(cea_t6_reasons(answer)) if number == 6
    reasons
  end

  # CEA-T6 asks what goes in parallel with the retractable-shoe coil that
  # causes interference. Manual p. 19 (capacitive coupling): an arc
  # suppressor in parallel with that coil. The p. 20 free-wheeling rectifier
  # is for the drop delay, not for interference.
  def cea_t6_reasons(answer)
    reasons = []
    reasons << "cea:t6_no_arc_suppressor" unless answer.match?(/supresor(?:es)? de arco/i)
    if answer.match?(/rueda libre/i) && !answer.match?(/retardo/i)
      reasons << "cea:t6_rectifier_as_interference_fix"
    end
    reasons
  end

  def elemont_reasons(number, answer)
    case number
    when 1
      [ ("t1:joint" unless answer.match?(/sin punto de uni[oó]n/i)) ].compact
    when 2
      missing = []
      missing << "t2:level" unless answer.match?(/Chapa nivel 3/i)
      missing << "t2:side" unless answer.match?(/\bSp3\b/)
      missing
    when 3
      answer.match?(/Seguridad Puerta nivel 4/i) && answer.match?(/Seguridad Puerta nivel 2/i) ? [] : [ "t3:neighbors" ]
    else
      reasons = []
      reasons << "t4:spare" if answer.match?(/\b(?:reemplaza|cambia|sustituye)\b/i)
      reasons << "t4:asks_again" if answer.match?(/¿[^?\n]*(?:identificar|cu[aá]l es)[^?\n]*\?/i)
      reasons
    end
  end
end
