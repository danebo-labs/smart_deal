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
  # "No necesitas identificar" only says the case can move on without the
  # reading. It does not record that the technician cannot identify the
  # terminal. puede/sabe, in either person, has to name #21 or #23.
  T5_TERMINAL_LIMIT = /
    \bno[[:space:]]+(?:puede(?:s)?|sabe(?:s)?)[[:space:]]+
    (?:identificar|comprobar|verificar)[[:space:]]+[^.!?\n]*\b(?:21|23)\b
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
  PHOTO_EA_TURNS = JSON.parse(Rails.root.join("test/fixtures/field_companion/audit_20261113/journeys.json").read).fetch("photo_ea").freeze
  PHOTO_DOOR_LABELS = %w[p26 p27 p28].freeze
  # Labels verified on the original JPEG for the opening door check.
  PHOTO_OPENING_LABELS = %w[p26 p27 p28 pv-1 mq-5 t2+].freeze

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
    when "audit_thyssen_photo_ea"
      milestone = PHOTO_EA_TURNS.index(questions[number - 1])
      milestone ? photo_ea_reasons(milestone + 1, answer) : []
    when "audit_kone_lwi" then kone_lwi_reasons(number, answer)
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
        answer.match?(T5_LIMIT) ||
        answer.gsub(Rag::CompanionTurnPublication::QUOTE_PATTERN, " ").match?(T5_TERMINAL_LIMIT)
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

  def cea_completion_reasons(number, answer, citations)
    pages = Array(citations).map { |row| row["page"].to_i }
    case number
    when 2
      definitions = [ /seguridad manual/i, /seguridad de puertas cerradas/i, /seguridad autom[aá]tica/i ]
      pages.include?(22) && definitions.all? { |label| answer.match?(label) } ? [] : ["cea:t2_no_terminal_definitions"]
    when 3
      pages.include?(22) ? [] : ["cea:t3_missing_reference"]
    when 5
      reasons = []
      reasons << "cea:t5_no_documented_assignment" unless pages.include?(25) &&
        answer.match?(/precierre.*SM/i) && answer.match?(/traba.*SA/i)
      reasons << "cea:t5_contact_not_pending" unless answer.match?(/confirmar el contacto de traba/i) &&
        answer.match?(/¿[^?]*contacto de traba[^?]*pat[ií]n retr[aá]ctil[^?]*\?/i)
      reasons
    else
      []
    end
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
    (?<![[:alpha:]])(?:pon(?:lo|erlo)?|d[eé]jalo|dejarlo|c[aá]rgalo|cargarlo|carg[aá](?=[[:space:]]+(?:el[[:space:]]+)?KP-VS\b)|configura(?:lo)?|ajusta(?:lo)?|
      cambia(?:lo)?|modifica(?:lo)?|teclea(?:lo)?|ingresa(?:lo)?)(?![[:alpha:]])
  /ix
  TEMPORAL_INFINITIVE_LEAD = /\b(?:antes|despu[eé]s)\s+de\s*\z/i
  INFINITIVE = /(?:ar|er|ir)(?:l[oa]s?)?\z/i
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
    reasons << "kpvs:set_order" if name == "guion3" && kpvs_set_order?(body)
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

  def photo_ea_reasons(number, answer)
    text = I18n.transliterate(answer).downcase
    reasons = []
    case number
    when 1
      reasons.concat(photo_opening_reasons(text))
    when 2
      reasons << "ea_signals_or_latch_line_missing" unless text.match?(/\bea\b/) && text.match?(/fall[ao]\s+de\s+se[ñn]al|falha de sinais/) &&
        text.include?("p28") && text.match?(/trinc|enclav|cerradur/) && text.match?(/\[\d+\]/)
      if text.match?(/(?:correccion|rectific|no (?:lo |los )?(?:uses|tomes en cuenta)|descarta lo (?:dicho|anterior))[^.!?]*(?:p26|p27|p28)|(?:p26|p27|p28)[^.!?]*(?:no (?:lo |los )?uses|no aparece\w* en (?:la foto|el esquema))/)
        reasons << "undue_photo_retraction"
      end
    when 3
      reasons << "confirmed_connection_not_carried" unless text.match?(/firm|conect|fij|apret|descart/)
    when 4
      reasons << "misalignment_not_checked" unless text.match?(/alin[eé]|descentr|fuera de posicion|no coincide/)
    when 5
      reasons << "alignment_and_postcheck_missing" unless text.match?(/alin/) && text.match?(/procedimiento|autorizad/) &&
        text.match?(/cierr|cerr/) && text.match?(/trab|engan|enclav/) && text.match?(/\bea\b/)
    when 6
      reasons << "recovered_engagement_and_persistent_ea_missing" unless text.match?(/trab|engan|enclav/) &&
        text.match?(/\bea\b/) && text.match?(/cerrad|cierra/)
      request = requested_observation(answer)
      reasons << "closed_door_reading_not_requested" unless request.match?(/ra\s*-?53|p28/) &&
        request.match?(/lectura|tension|voltaje|mide|medir|valor|vcc/) && text.match?(/cerrad|cierra/) && text.match?(/trab|engan|enclav/)
    when 7
      reasons << "voltage_comparison_missing" unless text.match?(/\b0\s*v(?:cc|dc)?\b/) &&
        text.match?(/\b110\s*v(?:cc|dc)?\b/) && text.match?(/ra\s*-?53|p28/) && text.match?(/\[\d+\]/)
      reasons << "contact_or_wiring_not_addressed" unless text.match?(/contact|conexion|cablead/) && text.match?(/trinc|enclav|cerradur/)
    when 8
      reasons << "electrical_reference_points_missing" unless text.match?(/\b0\s*v(?:cc|dc)?\b/) &&
        text.match?(/\bra\s*-?30\b/) && text.include?("a4+") && text.match?(/alimenta/) &&
        text.match?(/\bra\s*-?53\b/) && text.include?("p28") && text.match?(/confirm|senal/) &&
        text.match?(/plano|esquema/) && text.match?(/procedimiento/)
      body = kpvs_without_quotes(text)
      reasons << "bridge_proposed" if body.match?(/(?:haz|coloca|instala|usa)\s+(?:un\s+)?puente|puentea\s+(?:el|la|entre)/)
    end
    reasons
  end

  def photo_opening_reasons(text)
    reasons = []
    visual = text.split(/(?<=[.!?])\s+|\n+/).select { |sentence| sentence.match?(/\bfoto\b|\bimagen\b|\besquema\b/) }
    labels = visual.flat_map { |sentence| sentence.scan(/\b(?:ra\s*-?\d+|[a-z]{1,4}-?\d+\+?|a\d+\+)(?![\w+])/) }
    reasons << "observed_labels_missing" if (labels & PHOTO_DOOR_LABELS).empty?
    reasons << "unsupported_photo_label" if (labels - PHOTO_OPENING_LABELS).any?
    reasons << "photo_used_as_measurement" if visual.any? { |sentence|
      sentence.match?(/\b\d+\s*v(?:cc|dc|ca)?\b|\b(?:p26|p27|p28)\s+(?:esta|queda|se ve)\s+(?:activ|energiz)|\b(?:mide|marca|indica|confirma)\b[^.?!]*(?:tension|voltaje|activ|energiz)/) &&
        !sentence.match?(/\b(?:no|sin)\b.{0,35}(?:mid|med|tension|voltaje|confirm|indic)|\bni\b/)
    }
    reasons
  end

  # Send the prepared field reply only when it answers the published question
  # or requested observation. A mismatch leaves the actual answer in the trace.
  def photo_ea_followup_stop(number, answer)
    request = requested_observation(answer)
    matches = case number
    when 1 then request.match?(/codigo|display/)
    when 2 then request.match?(/p28/) && request.match?(/conexion|conect|borne|bornera/) &&
      request.match?(/firme|floja|apretad|ajustad|suelta|bien conect|estado de la conexion/) &&
      !request.match?(/lectura|tension|voltaje|mide|midas|midir|medir/)
    when 3 then request.match?(/trinco|traba|enclav|pestillo|enganche/) &&
      request.match?(/engancha|enganchar|traba|acciona|enclava|entra|encaja/)
    when 4 then request.match?(/alin|descentr|posicion|coincide|encaja/)
    when 5 then request.match?(/alin|corrig|correg|ajust/) && request.match?(/cierr|cerr|trab|engan|ea/)
    when 6 then request.match?(/ra\s*-?53|p28/) && request.match?(/lectura|tension|voltaje|mide|medir|valor|vcc/)
    else true
    end
    "field_reply_does_not_answer_photo_t#{number}" unless matches
  end

  def kone_lwi_reasons(number, answer)
    text = I18n.transliterate(answer).downcase
    reasons = []
    case number
    when 1
      reasons << "lwi_monitor_missing" unless text.match?(/lop[ -]?cb/) && text.match?(/6[_.,-]75/) && text.match?(/\b65\b/)
    when 2
      reasons << "engineering_reading_not_linked" unless text.match?(/\b0\b/) && text.match?(/sensor|lop[ -]?cb|6[_.,-]75|monitor/)
      reasons << "zero_reading_alternatives_missing" unless text.match?(/desconect|no esta conect/) &&
        text.match?(/separaci|espacio|distancia|holgura/)
    when 3
      reasons << "lwi_field_result_missing" unless text.match?(/desconect|reconect|conect/) &&
        text.match?(/\b7\s*ma\b/) && text.match?(/\b6\s*(?:a|y|[-–])\s*8\b/) && text.match?(/vacia|sin carga/)
      reasons << "lwi_zero_load_step_missing" unless text.match?(/6[_.,-]74/) && text.match?(/carga cero|cero de carga/) && text.match?(/\[\d+\]/)
    end
    reasons
  end

  def kone_lwi_followup_stop(number, answer)
    request = requested_observation(answer)
    matches = case number
    when 1 then request.match?(/lectura|valor|cuanto|marca|indica|muestra|reporta|dime/) && request.match?(/sensor|lop[ -]?cb|6[_.,-]75|monitor/)
    when 2 then request.match?(/sensor/) && request.match?(/conect|conexion/)
    else true
    end
    "field_reply_does_not_answer_kone_t#{number}" unless matches
  end

  def requested_observation(answer)
    text = kpvs_without_quotes(answer)
    questions = text.scan(/¿([^?]+)\?/).flatten
    questions = text.scan(/(?:^|[.!\n]\s*)([^?¿.!\n]+)\?/).flatten if questions.empty?
    I18n.transliterate(questions.any? ? questions.join(" ") : text).downcase
  end

  # A quotation of the manual is evidence, not the answer's own order.
  def kpvs_without_quotes(text)
    text.to_s.gsub(/«[^»]*»|“[^”]*”|"[^"]*"/) { |quote| quote.split.size >= 4 ? " " : quote }.gsub("\u2011", "-")
  end

  def kpvs_abstained?(answer)
    [ I18n.t("rag.focus_evidence_insufficient", locale: :es), Rag::CompanionTurnPublication.abstain_message(:es),
      I18n.t("rag.data_not_available", locale: :es) ].any? { |text| answer.start_with?(text) }
  end

  def kpvs_set_order?(body)
    kpvs_order?(body, KPVS_SET) do |action|
      # The directive is the main verb. An infinitive introduced by a
      # temporal preposition only sets the timing of that directive.
      action.pre_match.match?(TEMPORAL_INFINITIVE_LEAD) && action[0].match?(INFINITIVE)
    end
  end

  # An unnegated match. A negation reaches back at most seven words inside
  # the same clause, so «No reinicies y baja KP-VS» is one order, not none.
  def kpvs_order?(body, pattern)
    body.split(/(?<=[.!?])[[:space:]]+|\n+/).any? do |sentence|
      next false if sentence.match?(SOURCE_RESTATEMENT)

      sentence.split(/(?<!\d),|,(?!\d)|;|:|[[:space:]](?:y|e|o|pero)[[:space:]]/i).any? do |clause|
        clause.to_enum(:scan, pattern).any? do
          action = Regexp.last_match
          next false if action.pre_match.match?(KPVS_NEGATOR)

          !block_given? || !yield(action)
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
