# frozen_string_literal: true

require "test_helper"

class Rag::DocumentIdentityScopeTest < ActiveSupport::TestCase
  POISON = [ "BM/B1", "61:U/N", "XB21", "00 71", "6 ± 1 mm" ].freeze
  CEA15_BODY = "En la placa CEA15 el código 8 es alta temperatura en el motor.".freeze

  test "MH matches MH and does not match MHX" do
    catalog = catalog_for(
      entry("mh-doc", designators: [ "MH" ])
    )

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      kept = Rag::DocumentIdentityScope.apply(
        [ chunk("mh-doc", "cuerpo del plano MH") ],
        episode(identifiers: %w[MH])
      )
      rejected = Rag::DocumentIdentityScope.apply(
        [ chunk("mh-doc", "cuerpo del plano MH") ],
        episode(identifiers: %w[MHX])
      )

      assert_equal "cuerpo del plano MH", kept.chunks.first[:content]
      assert_includes rejected.chunks.first[:content], "Reference only, other equipment."
      assert_not_includes rejected.chunks.first[:content], "cuerpo del plano MH"
    end
  end

  test "match, generic, other equipment, and a private manual" do
    catalog = catalog_for(
      entry("cea", brands: [ "Controles S.A." ], designators: [ "CEA15", "CEA15+", "CEA15P" ]),
      entry("mono", brands: [ "Monarch" ], designators: [ "NICE3000" ]),
      entry("note", generic: true),
      entry("cea51", brands: [ "Controles S.A." ], designators: [ "CEA51FB" ])
    )
    chunks = [
      chunk("cea", CEA15_BODY, canonical_name: "Manual CEA15"),
      chunk("mono", "Cortocircuitar BM/B1 y BM/B2.", canonical_name: "Monarch", page: 84,
            heading: "## Door machine"),
      chunk("note", "Nota interna de citofono.", canonical_name: "Citofono"),
      chunk("own", "Procedimiento del manual de la cuenta.", account_id: "9", canonical_name: "Cliente")
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))

      assert_not result.blocked
      assert_equal 1, result.undeclared_private
      assert_equal CEA15_BODY, result.chunks[0][:content]
      assert_equal "Nota interna de citofono.", result.chunks[2][:content]
      assert_equal "Procedimiento del manual de la cuenta.", result.chunks[3][:content]
      redacted = result.chunks[1][:content]
      assert_equal(
        "Reference only, other equipment. Document: Monarch. Page: 84. Section: Door machine.",
        redacted
      )
      assert_not_includes redacted, "BM/B1"
      assert_nil result.chunks[1][:metadata]["section_identity"]
      assert_equal "Cortocircuitar BM/B1 y BM/B2.", chunks[1][:content].lines.last.strip
    end
  end

  test "a general document without a confirmed entry blocks the scope" do
    catalog = catalog_for(entry("cea", designators: [ "CEA15" ]))
    chunks = [
      chunk("cea", CEA15_BODY),
      chunk("missing", "Cortocircuitar BM/B1.")
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      result = Rag::DocumentIdentityScope.apply(chunks, episode)
      assert result.blocked
      assert_equal "Cortocircuitar BM/B1.", result.chunks.last[:content]
    end
  end

  test "flag off does not retrieve and the unconfirmed catalog cannot activate" do
    with_flag(nil) do
      assert_not Rag::DocumentIdentityScope.applicable?(episode)
      service = BedrockRagService.allocate
      service.define_singleton_method(:retrieve_chunks) { flunk "retrieve_chunks" }
      assert_nil service.send(
        :document_identity_scope_result,
        "pregunta",
        episode: episode,
        response_locale: :es,
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        account_id: 1,
        user_id: nil,
        conversation_session_id: nil,
        correlation_id: "c"
      )
    end

    catalog = Rag::DocumentIdentityCatalog.load
    assert_equal 204, catalog.entries.size
    assert_equal 204, catalog.unconfirmed_count
    assert_not catalog.activatable?

    with_flag("true") do
      assert_not Rag::DocumentIdentityScope.applicable?(episode)
      Rag::DocumentIdentityCatalog.with_catalog(catalog_for(entry("cea", designators: [ "CEA15" ], confirmed: true))) do
        assert Rag::DocumentIdentityScope.applicable?(episode)
        assert_not Rag::DocumentIdentityScope.applicable?(episode(manufacturer_status: "unknown_confirmed"))
      end
    end
  end

  test "lookup key is document_id because the sidecar uri is not the s3 key" do
    entry = Rag::DocumentIdentityCatalog.load.find(
      "1",
      "9a4fa817-b9e8-4a9e-ae83-526c0731e603"
    )
    uri = "s3://multimodal-source-destination/#{entry.s3_key}"

    assert entry.s3_key.end_with?("manual-cea15p.pdf")
    assert_not_equal entry.s3_key, uri
    assert_includes entry.brands, "Controles S.A."
    assert_includes entry.designators, "CEA15"
    assert_not entry.confirmed
  end

  test "rendered generation prompt keeps the CEA15 body and drops the other equipment" do
    catalog = catalog_for(
      entry("cea", brands: [ "Controles S.A." ], designators: [ "CEA15" ]),
      entry("mh", brands: [ "Elemont" ], designators: [ "MH" ]),
      entry("monarch", brands: [ "Monarch" ], designators: [ "NICE3000" ]),
      entry("kone", brands: [ "KONE" ], designators: [ "MX05" ]),
      entry("blt", brands: [ "BLT" ], designators: [ "MPK708C" ])
    )
    chunks = [
      chunk("cea", CEA15_BODY, canonical_name: "Manual CEA15", page: 84),
      chunk("mh", "Plano Elemont MH: seguridad de puerta.", canonical_name: "Plano MH", page: 2),
      chunk("monarch", "Cortocircuitar BM/B1 y BM/B2 en el CTB.", canonical_name: "Monarch", page: 84),
      chunk("kone", "Falta imán 00 71. Contacto 61:U/N. Desconecte XB21.", canonical_name: "KONE MX05", page: 444,
            section_identity: "61:U/N"),
      chunk("blt", "La distancia horizontal es de 6 ± 1 mm.", canonical_name: "BLT MPK708C", page: 89)
    ]

    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      applied = Rag::DocumentIdentityScope.apply(chunks, episode(identifiers: %w[MH CEA15]))
      assert_not applied.blocked
      route = Rag::StructuredEvidenceRoute.new(
        question: "Elemont MH con placa CEA15, falla en puerta 1: el imán no magnetiza. ¿Qué reviso?",
        account: accounts(:legacy),
        entity_s3_uris: [],
        entity_sources: [],
        force_entity_filter: false,
        response_locale: :es,
        rag_service: Object.new,
        generator: Object.new,
        expander: Object.new
      )
      selected = route.send(:select_generation_chunks, applied.chunks, ambiguity: nil)
      prompt = route.send(:generation_prompt, selected)

      assert_includes prompt, CEA15_BODY
      POISON.each { |text| assert_not_includes prompt, text }
    end
  end

  private

  def episode(identifiers: %w[MH CEA15], manufacturer_status: "known")
    {
      "v" => 1,
      "episode_id" => "ep-test",
      "updated_at" => Time.current.iso8601,
      "facts" => {
        "manufacturer" => {
          "value" => "Elemont",
          "status" => manufacturer_status,
          "source" => "user"
        }
      },
      "identifiers" => identifiers.map { |value| { "value" => value, "source" => "user" } }
    }
  end

  def catalog_for(*entries)
    Rag::DocumentIdentityCatalog.new("documents" => entries)
  end

  def entry(document_id, brands: [], designators: [], generic: false, confirmed: true)
    {
      "account_id" => "1",
      "document_id" => document_id,
      "s3_key" => "bulk_uploads/1/#{document_id}.pdf",
      "display_name" => document_id,
      "brands" => brands,
      "designators" => designators,
      "generic" => generic,
      "confirmed" => confirmed
    }
  end

  def chunk(document_id, content, account_id: "1", canonical_name: document_id, page: 1,
            section_identity: nil, heading: nil)
    body = heading.present? ? "#{heading}\n#{content}" : content
    metadata = {
      "account_id" => account_id,
      "document_id" => document_id,
      "canonical_name" => canonical_name,
      "page_number" => page
    }
    metadata["section_identity"] = section_identity if section_identity
    {
      rank: 1,
      content: body,
      metadata: metadata,
      chunk_sha256: Digest::SHA256.hexdigest(body)
    }
  end

  def with_flag(value)
    original = ENV.fetch("DOCUMENT_IDENTITY_SCOPE_ENABLED", nil)
    if value.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = value
    end
    yield
  ensure
    if original.nil?
      ENV.delete("DOCUMENT_IDENTITY_SCOPE_ENABLED")
    else
      ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = original
    end
  end
end
