# frozen_string_literal: true

require "test_helper"

module Stage1Live
  NO_RUN = true
end
load Rails.root.join("script/field_companion/run_stage1_live.rb")

# The pure parts of the live runner: how a turn is judged and how the photos
# are prepared. No database, no network, no model.
class OtisCase29RunnerTest < ActiveSupport::TestCase
  P1 = "MANUAL DE AYUDA TÃ‰CNICA ( Act. Marzo 2010 ) (p1-123)"

  test "T1 is judged without an episode before it: the first turn of a new case" do
    summary = {
      "turn_status" => "completed", "asked_again" => "¿Qué evento aparece en el historial?", "published" => "¿Qué evento aparece en el historial?",
      "identifiers" => [ { "value" => "GECGB" } ], "photo" => "loaded", "visible_text" => [ "Ad*** COR CR ][][" ],
      "all_observations" => [ "En el.piso 3 la puerta intenta cerrar y vuelve abrir" ], "citations" => [], "pending" => nil
    }

    verdict = Stage1Live.send(:judge, "Otis T1", nil, summary)

    assert verdict["accepted"], verdict["first_divergence"]
    assert_equal "accepted", verdict["reason"]
  end

  test "T1 is not accepted when Danebo asked about a variant of the manual instead of the history event" do
    front_or_rear = "¿La puerta del piso 3 es frontal o trasera?"
    summary = {
      "turn_status" => "completed", "asked_again" => front_or_rear, "published" => "Pregunta: #{front_or_rear}",
      "identifiers" => [ { "value" => "GECGB" } ], "photo" => "loaded", "visible_text" => [ "Ad*** COR CR ][][" ],
      "all_observations" => [ "En el.piso 3 la puerta intenta cerrar y vuelve abrir" ], "citations" => [], "pending" => nil
    }

    verdict = Stage1Live.send(:judge, "Otis T1", nil, summary)

    assert_not verdict["accepted"]
    assert_equal [ "history_event_or_equivalent_requested" ], summary["rubric"]["failed"]
    assert_equal "acceptance", verdict["reason"]
  end

  test "the verdict of a turn after T1 reads the question that was open before it, from the case state" do
    open_question = { "id" => "q4", "question" => "¿La puerta se detiene siempre en el mismo punto?",
                      "parts" => [ { "id" => "p4", "role" => "main", "text" => "¿La puerta se detiene siempre en el mismo punto?" } ] }
    opened = Rag::ActiveEpisode.new
    opened.pending_question = open_question
    summary = {
      "turn_status" => "completed", "correlation_id" => "query:t5", "pending" => nil, "pending_before" => open_question,
      "part_states" => {}, "observations" => [ "Encontré residuos en la guía y los retiré" ], "asked_again" => nil, "citations" => [],
      "published" => "Tras retirar los residuos de la guía, la puerta cerró por completo y el 0102 no volvió a aparecer en tu prueba. " \
        "Lo más probable es que el cambio se deba a esa limpieza.\n\nSigue sin verificarse DCL ni DFC.",
      "checks" => [ { "subject" => "No llegamos a verificar DCL ni DFC", "status" => "not_done", "correlation_id" => "query:t5" } ]
    }

    verdict = Stage1Live.send(:judge, "Otis T5", opened, summary)

    assert verdict["accepted"], verdict["first_divergence"]
    assert_nil summary["rubric"]["failed"].first
    assert_equal open_question, summary["opened_pending"]
  end

  test "photo preparation fits the frame keeping the proportion, with grey borders, and is repeatable" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.jpg")
      Vips::Image.black(300, 600).new_from_image([ 255, 255, 255 ]).write_to_file(source)
      first = Stage1Live::PhotoPrep.prepare(source, File.join(directory, "a.jpg"))
      second = Stage1Live::PhotoPrep.prepare(source, File.join(directory, "b.jpg"))

      assert_equal [ 576, 448 ], first["prepared_size"]
      assert_equal first["prepared_sha256"], second["prepared_sha256"], "the same source gives the same bytes"
      image = Vips::Image.new_from_file(first["prepared"])
      left = image.crop(0, 0, 20, 448).avg
      center = image.crop(280, 200, 16, 16).avg
      assert_in_delta 128, left, 3, "free area is neutral grey"
      assert_operator center, :>, 240, "the photo keeps its place in the middle"
      assert_equal Stage1Live::PhotoPrep.parameters, first["parameters"]
      assert_raises(ArgumentError) { Stage1Live::PhotoPrep.prepare(source, File.join(directory, "c.jpg"), expected_sha256: "0" * 64) }
    end
  end

  test "the supplied photos in the repository are the ones the live run recorded and prepare to the same bytes" do
    Dir.mktmpdir do |directory|
      Stage1Live::PhotoPrep::SOURCES.each do |number, source|
        done = Stage1Live::PhotoPrep.prepare(source.fetch("file"), File.join(directory, "t#{number}.jpg"), expected_sha256: source.fetch("sha256"))

        assert_equal [ 576, 448 ], done["prepared_size"]
        assert_equal Stage1Live::PhotoPrep::PREPARED_SHA256.fetch(number), done["prepared_sha256"] if done.dig("parameters", "libvips") == "8.18.0"
      end
    end
  end
end
