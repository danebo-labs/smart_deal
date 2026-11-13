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
    when /\A(?:kpvs|guion3)/ then kpvs_reasons(name, number, answer)
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
    reasons << "cea:t3_no_levels" if number == 3 && !cea_t3_levels?(answer)
    reasons.concat(cea_t6_reasons(answer)) if number == 6
    # Manual p. 23: SM «NO incluye los contactos por acción de operador de
    # puerta automática».
    reasons << "cea:t7_operator_in_sm" if number == 7 && answer.match?(/\A[\s*_]*s[ií]\b/i)
    reasons
  end

  # CEA-T3 asks which voltage is a 1 and which a 0. Manual p. 22: 24 Vcc is
  # "1" and 0 Vcc is "0".
  def cea_t3_levels?(answer)
    answer.match?(/24\s*Vcc/i) && answer.match?(/(?<![\d.,])0\s*Vcc/i)
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

  # Thyssen FDN MCINV4, KP-VS. Manual p. 18 (§19.13): with very loud noise the
  # parameter is decreased «hasta el mínimo de [3,0]». Manual p. 15 (§18.5):
  # "KP-VS" = [3,5] is the value of the menu PID at installation. §18.4 gives
  # the Eberle 7,5 kW / 220 V motor as an example of the plate data.
  # The reasons read the published answer only, with the quotations removed,
  # and they do not use the product's own filters.
  KPVS_DECREASE = /
    (?<![[:alpha:]])(?:red[uú]ce(?:lo)?|reducir(?:lo)?|reduzcas?|disminuye(?:lo)?|disminuir(?:lo)?|
      b[aá]jalo|baja|bajar(?:lo)?|bajes?|(?:sigue|seguir|siga)[[:space:]]+(?:bajando|reduciendo))(?![[:alpha:]])
  /ix
  KPVS_SET = /
    (?<![[:alpha:]])(?:pon(?:lo|erlo)?|d[eé]jalo|dejarlo|c[aá]rgalo|cargarlo|configura(?:lo)?|ajusta(?:lo)?|
      cambia(?:lo)?|modifica(?:lo)?|teclea(?:lo)?|ingresa(?:lo)?)(?![[:alpha:]])
  /ix
  KPVS_NEGATOR = /(?<![[:alpha:]])(?:no|nunca|evita|evitar|sin|tampoco)(?![[:alpha:]])(?:[[:space:]]+[[:alpha:]]+){0,7}[[:space:]]*\z/i
  # «La fuente indica disminuir KP-VS «hasta el mínimo de [3,0]»»: what the manual says, not an order.
  SOURCE_RESTATEMENT = /\A[[:space:]]*(?:seg[uú]n\b|la[[:space:]]+fuente[[:space:]]+(?:indica|dice|establece|pide)|el[[:space:]]+manual[[:space:]]+(?:indica|dice|establece|pide))/i
  INSTALLATION_REFERENCE = /referencia de instalaci[oó]n|puesta en marcha|comisionamiento|18\.5/i
  PENDING_STATE = /ingenier[ií]a|pendiente|sin cambio|no se ha cambiado|nadie[[:space:]]+(?:ha[[:space:]]+)?cambi/i
  RESOLVES_NOISE = /
    (?:resolver[aá]|solucionar[aá]|eliminar[aá]|quitar[aá]|corregir[aá]|acabar[aá][[:space:]]+con)[^.\n]{0,40}ruido |
    ruido[^.\n]{0,40}(?:se[[:space:]]+(?:resuelve|soluciona|elimina)|quedar[aá][[:space:]]+resuelto)
  /ix

  def kpvs_reasons(name, number, answer)
    body = kpvs_without_quotes(answer)
    reasons = []
    reasons << "kpvs:no_answer" if kpvs_abstained?(answer)
    reasons << "kpvs:decrease_order" if kpvs_order?(body, KPVS_DECREASE)
    reasons << "kpvs:set_order" if name == "guion3" ? kpvs_order?(body, KPVS_SET) : false
    if name == "guion3"
      reasons.concat(guion3_reasons(number, body, answer))
    else
      # Single turn: nothing in the technician's message names Engineering, so
      # the referral is kept when the model writes it but is not demanded.
      reasons.concat(kpvs_floor_reasons(name, body, answer))
    end
    reasons << "kpvs:3_5_unlabeled" if body.match?(/3,5/) && !body.match?(INSTALLATION_REFERENCE)
    reasons.uniq
  end

  def guion3_reasons(number, body, answer)
    case number
    when 1
      reasons = []
      reasons << "g3t1:no_engineering" unless body.match?(/ingenier[ií]a/i)
      reasons << "g3t1:value_not_pending" unless body.match?(/KP-VS/) && body.match?(/pendiente|falta|necesit|qu[eé] valor|cu[aá]l es|valor (?:actual|de)|sin (?:el )?valor/i)
      reasons
    when 2
      reasons = kpvs_floor_reasons("kpvs", body, answer)
      reasons << "g3t2:example_not_distinguished" unless body.match?(/ejemplo/i) && body.match?(/placa/i)
      reasons << "g3t2:example_as_plate" if kpvs_order?(body, /(?:usa|utiliza|carga|toma|ingresa)(?:[[:space:]]+(?:los|esos|estos))?[[:space:]]+[^.\n]{0,25}7,5[[:space:]]*kW/i)
      reasons
    else
      reasons = []
      reasons << "g3t3:no_3_5" unless body.match?(/3,5/)
      reasons << "g3t3:resolves_noise" if kpvs_order?(body, RESOLVES_NOISE)
      reasons << "g3t3:pending_lost" unless body.match?(PENDING_STATE)
      reasons
    end
  end

  # The minimum may sit in the cited quote («hasta el mínimo de [3,0]»); the
  # orders and the comparison are read outside the quotes.
  def kpvs_floor_reasons(name, body, answer = body)
    reasons = []
    reasons << "kpvs:no_minimum" unless answer.delete("[]").match?(/m[ií]nimo[^.\n]{0,60}3,0|3,0[^.\n]{0,60}m[ií]nimo/i)
    if name == "kpvs_exact"
      reasons << "kpvs:not_at_minimum" unless body.match?(/(?:en|igual al|alcanz\w+ el)[[:space:]]+(?:el[[:space:]]+)?m[ií]nimo|ya est[aá][[:space:]]+en[[:space:]]+3,0/i)
    else
      reasons << "kpvs:no_comparison" unless body.match?(/2,5/) && body.match?(/por debajo|debajo del|menor/i)
    end
    reasons
  end

  # A quotation of the manual is evidence, not the answer's own order.
  def kpvs_without_quotes(text)
    text.to_s.gsub(/«[^»]*»|“[^”]*”|"[^"]*"/) { |quote| quote.split.size >= 4 ? " " : quote }.gsub("\u2011", "-")
  end

  def kpvs_abstained?(answer)
    [ I18n.t("rag.focus_evidence_insufficient", locale: :es), Rag::CompanionTurnPublication.abstain_message(:es),
      I18n.t("rag.data_not_available", locale: :es) ].any? { |text| answer.start_with?(text) }
  end

  # An unnegated match. A negation reaches back at most seven words inside
  # the same clause, so «No reinicies y baja KP-VS» is one order, not none.
  def kpvs_order?(body, pattern)
    body.split(/(?<=[.!?])[[:space:]]+|\n+/).any? do |sentence|
      next false if sentence.match?(SOURCE_RESTATEMENT)

      sentence.split(/(?<!\d),|,(?!\d)|;|:|[[:space:]](?:y|e|o|pero)[[:space:]]/i).any? do |clause|
        clause.to_enum(:scan, pattern).any? do
          !clause[0...Regexp.last_match.begin(0)].match?(KPVS_NEGATOR)
        end
      end
    end
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
