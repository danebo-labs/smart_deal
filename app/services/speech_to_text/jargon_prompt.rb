# frozen_string_literal: true

module SpeechToText
  # The jargon lever for the OpenAI-compatible providers: the `prompt` field of
  # the transcription endpoint, which both vendors read as preceding context and
  # use to bias spelling. Amazon Transcribe's equivalent is a custom vocabulary
  # resource created out of band in AWS, so this module does not apply to it.
  #
  # Written as sentences, not as a term list, because that is the only form that
  # measured anything. Paired runs against Groq, same clips, 2026-09-09, under a
  # cent all in:
  #
  #                        no prompt              this prompt
  #   brand, clip A        "Kone Monoespace"      "Kone MonoSpace"    (correct)
  #   brand, clip B        "Kony Mono Espacio"    "Kone MonoEspacio"  (partial)
  #   brand, clip B        "Jingles 3300"         "Shingles 3300"     (no gain)
  #   homophone            "rosa"                 "rosa"              (no gain)
  #   fault code           "A32. 4"               "A32. 4"            (no gain)
  #   silent clip          "Gracias."             "Gracias por ver el video."
  #   room noise, no voice "y"                    "Más información www.mono.org."
  #
  # A comma-separated version of the same vocabulary moved nothing at all, so the
  # endpoint is imitating preceding context rather than reading a glossary.
  #
  # It is kept on despite the last two rows, and the reason is which error is
  # dangerous. Everything the prompt worsens is obvious garbage over audio with
  # no speech, and the certifier deletes it in one gesture — the panel is never
  # auto-confirmed (fixed rule 3). What it improves is brand spelling, which is
  # plausible-wrong: "Jingles 3300" in the equipment header of a signed report
  # reads like something a technician might have said. Trading a visible nuisance
  # for less of that is the trade this module exists to make. The proper fix for
  # the empty-audio rows is the client-side RMS guard still pending from Fase 5,
  # which stops silence from reaching a provider at all.
  #
  # Note the last row: "mono.org" looks like bleed from "MonoSpace", so the
  # prompt does not merely make hallucinations longer, it can seed them. One more
  # reason the string stays short.
  #
  # Do not grow it hoping to fix the middle rows. The homophone survived with
  # "La puerta de cabina roza en el marco" verbatim in the prompt; the certifier's
  # edit is the fix for that, and Rails normalisation for the code spacing.
  #
  # Carries no numbers at all, and that is a constraint rather than an omission:
  # the field biases the transcript toward whatever it names, so a fault code or
  # a count here could put a value in a certification report that nobody said.
  # The norm number was tried and fixed nothing, which left no reason to keep the
  # only digits in the string. The endpoint also keeps only the last 224 tokens,
  # so a string that grows silently drops its own tail.
  module JargonPrompt
    ENV_KEY = "STT_JARGON_PROMPT"

    DEFAULT = "Informe de certificación de ascensores. " \
              "La puerta de cabina roza en el marco. " \
              "Holgura de puertas fuera de tolerancia. " \
              "El foso tiene filtración y el contrapeso está desalineado. " \
              "El limitador de velocidad y el paracaídas fueron probados. " \
              "Variador de frecuencia, operador de puertas, carga útil. " \
              "Equipos Kone MonoSpace, Otis, Schindler, ThyssenKrupp, Mitsubishi."

    module_function

    # @return [String] the configured hint, or "" to send none. Setting
    #   STT_JARGON_PROMPT to an empty value is the documented way to turn the
    #   lever off in one environment without a deploy, which is what makes an
    #   A/B of it possible at all.
    def text
      ENV.fetch(ENV_KEY, DEFAULT).to_s
    end
  end
end
