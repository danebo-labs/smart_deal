# frozen_string_literal: true

require "test_helper"

class Rag::PinnedEntityScopeResolverTest < ActiveSupport::TestCase
  MANUAL_URI = "s3://smart-deal-dev-kb/uploads/manual_plataforma.pdf"
  IMAGE_URI  = "s3://smart-deal-dev-kb/uploads/hydraulic.jpg"

  def active_entities
    {
      "Manual Plataforma Elevadora Batería" => {
        "canonical_name" => "Manual Plataforma Elevadora Batería",
        "wa_filename" => "danebo_fidelity_v2_22_paginas.pdf",
        "source_uri" => MANUAL_URI,
        "entity_type" => "document",
        "aliases" => [ "Plataforma Tijera Manual", "pruebas de funcionamiento" ]
      },
      "Hydraulic Electro-Hydraulic Schematic Diagram" => {
        "canonical_name" => "Hydraulic Electro-Hydraulic Schematic Diagram",
        "wa_filename" => "IMG_20260609_121243.jpg",
        "source_uri" => IMAGE_URI,
        "entity_type" => "image_upload",
        "aliases" => [ "P41", "P42", "FRRV1", "esquema hidráulico" ]
      }
    }
  end

  test "narrows by an accented canonical name" do
    result = resolve("Según el Manual Plataforma Elevadora Bateria, ¿qué debo revisar?")

    assert result.narrowed
    assert_equal [ MANUAL_URI ], result.uris
  end

  test "narrows by a literal short code" do
    result = resolve("¿Qué indica P41?")

    assert result.narrowed
    assert_equal [ IMAGE_URI ], result.uris
  end

  test "narrows by an exact compound alias containing a generic word" do
    result = resolve("¿Qué etiquetas aparecen en el esquema hidráulico?")

    assert result.narrowed
    assert_equal [ IMAGE_URI ], result.uris
  end

  test "does not narrow from generic document words" do
    result = resolve("Revisa el manual y el esquema")

    assert_not result.narrowed
    assert_equal [ MANUAL_URI, IMAGE_URI ], result.uris
  end

  test "keeps all pins for a semantic question without an explicit identity" do
    result = resolve("¿Qué debo revisar antes de operar el equipo?")

    assert_not result.narrowed
    assert_equal [ MANUAL_URI, IMAGE_URI ], result.uris
  end

  test "excludes an entity named in a negative clause" do
    result = resolve(
      "Usa el Manual Plataforma Elevadora Bateria. No uses el esquema hidraulico."
    )

    assert result.narrowed
    assert_equal [ MANUAL_URI ], result.uris
  end

  test "keeps all pins when two entities have equally strong explicit matches" do
    result = resolve("Compara Plataforma Tijera Manual con IMG_20260609_121243.jpg")

    assert_not result.narrowed
    assert_equal [ MANUAL_URI, IMAGE_URI ], result.uris
  end

  private

  def resolve(question)
    Rag::PinnedEntityScopeResolver.new(
      question: question,
      active_entities: active_entities,
      allowed_uris: [ MANUAL_URI, IMAGE_URI ]
    ).resolve
  end
end
