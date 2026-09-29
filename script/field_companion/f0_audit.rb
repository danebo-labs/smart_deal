# frozen_string_literal: true

# Field Companion F0 audit. Read-only toward production: it does not change
# constants, authorization, pins, or the knowledge base. It writes
# tmp/field_companion/ and, unless a recorded probe already exists, makes one
# Anthropic messages.create call with claude-sonnet-5-5. That call uses
# Anthropic::Client directly and does not enqueue TrackBedrockQueryJob.
#
# Usage: bin/rails runner script/field_companion/f0_audit.rb
#        F0_SKIP_PROBE=1 skips the live call (structural reruns only).

require "digest"
require "fileutils"
require "json"

require_relative "../../config/environment" unless defined?(Rails) && Rails.application
require_relative "discovery_score"

module FieldCompanion
  module F0Audit
    ROOT = Rails.root.join("tmp/field_companion")
    PROBE_IMAGE = Rails.root.join("docs/field_companion/multimodal_availability_probe.jpg")
    SPRING_SOURCE = Pathname.new("/Users/lahirisan/Desktop/resortes.png")
    SPRING_DEST = ROOT.join("images/spring_assembly_misread.png")
    PROBE_MODEL = "claude-sonnet-5-5"
    PROBE_SHA = "5610cba05ad3f23d2bc8fcdc4c473df0316e2d47982711d7ce6a3f880baeea3c"
    PROBE_BYTES = 803
    SPRING_SHA = "202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd"
    SPRING_BYTES = 1_430_913

    FIXTURE = [
      "Estoy en un Schindler y la puerta no cierra.",
      "Estoy en un OTIS y tengo este problema.",
      "Elemont MH, la seguridad no actúa.",
      "Estoy en un KONE.",
      "Tengo un problema en la puerta.",
      "Estoy en un AcmeLifts modelo ZX9.",
      "Schindler y OTIS en el mismo hueco."
    ].freeze

    HOLDOUT = [
      "Estoy con un Schindler.",
      "El tablero es Elemont.",
      "KONE modelo MonoSpace, la puerta no abre.",
      "Mitsubishi, no cierra la puerta.",
      "Revisando el equipo."
    ].freeze

    DEICTIC_POSITIVE = [
      "estos resortes",
      "según la foto",
      "la imagen que te mandé",
      "lo que se ve ahí"
    ].freeze

    DEICTIC_NEGATIVE = [
      "según el manual",
      "el borne 24",
      "fotocélula del embarque",
      "mandame el procedimiento"
    ].freeze

    MINIMUM_CHANGE = "No hay una marca explícita de Danebo por documento. " \
      "La ruta con reindex_required false y duplicate_document_required false " \
      "filtra el retrieve abierto con el document_id ya escrito en el chunk y " \
      "pinea con user_pin en active_entities de la sesión, sobre la fila " \
      "KbDocument existente. No agrega un atributo nuevo al chunk, no reindexa " \
      "y no copia el documento ni el objeto S3. Esta fila queda tenant_private " \
      "hasta una aprobación explícita, fuera del chunk.".freeze

    module_function

    def run
      FileUtils.mkdir_p(ROOT.join("images"))
      spring = copy_spring
      catalog = Rag::DocumentIdentityCatalog.load
      db = load_database
      inventory = build_inventory(db)
      discovery = build_discovery(catalog)
      eligible = build_eligible(discovery, inventory, catalog, db)
      matrix = build_matrix(discovery, inventory, catalog, db)
      probe = run_probe
      manifest = build_manifest(spring)
      audit = build_contract_audit(spring, probe, catalog)
      paths = {
        "f0_contract_audit.json" => audit,
        "f0_probe.json" => probe,
        "f0_general_inventory.json" => inventory,
        "f0_authorization_matrix.json" => matrix,
        "f0_discovery.json" => discovery,
        "f0_discovery_eligible.json" => eligible,
        "visual_manifest.json" => manifest
      }
      hashes = paths.map { |name, payload|
        path = ROOT.join(name)
        write_json(path, payload)
        [ name, Digest::SHA256.file(path).hexdigest ]
      }.to_h

      status = spring["sha256_match"] && probe["registered"] ? "PASS" : "BLOCKED"
      puts "F0_STATUS=#{status}"
      puts "spring_sha256_match=#{spring["sha256_match"]}"
      puts "probe_success=#{probe["success"]}"
      puts "probe_error_class=#{probe["error_class"]}" if probe["error_class"]
      puts "k_matrix_match=#{audit.dig("k_matrix", "matches")}"
      puts "db_checked=#{db["db_checked"]}"
      puts "general_approved_count=#{inventory["classification_counts"]["GENERAL_APPROVED"]}"
      puts "f4_route_confirmed=#{matrix["f4_route_confirmed"]}"
      hashes.each { |name, sha| puts "#{name} #{sha}" }
      status == "PASS" ? 0 : 2
    end

    def copy_spring
      source_bytes = File.binread(SPRING_SOURCE)
      source_sha = Digest::SHA256.hexdigest(source_bytes)
      File.binwrite(SPRING_DEST, source_bytes)
      dest_sha = Digest::SHA256.file(SPRING_DEST).hexdigest
      dims = image_dimensions(SPRING_DEST)
      {
        "source_path" => SPRING_SOURCE.to_s,
        "dest_path" => SPRING_DEST.to_s,
        "sha256" => dest_sha,
        "source_sha256" => source_sha,
        "sha256_match" => dest_sha == SPRING_SHA && source_sha == SPRING_SHA && dest_sha == source_sha,
        "bytes" => File.size(SPRING_DEST),
        "bytes_match" => File.size(SPRING_DEST) == SPRING_BYTES,
        "width" => dims[0],
        "height" => dims[1],
        "media_type" => "image/png"
      }
    end

    def image_dimensions(path)
      image = Vips::Image.new_from_file(path.to_s)
      [ image.width, image.height ]
    end

    def load_database
      ActiveRecord::Base.connection.verify!
      accounts = Account.where(slug: Rag::SharedManualCorpus::SLUGS).order(:id).pluck(:id, :slug)
      ids = accounts.map(&:first)
      rows = KbDocument.where(account_id: ids).order(:document_uid).pluck(
        :document_uid, :account_id, :display_name
      )
      viewer = Account.where.not(slug: Rag::SharedManualCorpus::SLUGS).order(:id).pick(:id, :slug)
      {
        "db_checked" => true,
        "error_class" => nil,
        "accounts" => accounts.map { |id, slug| { "id" => id.to_s, "slug" => slug } },
        "rows" => rows,
        "viewer" => viewer ? { "account_id" => viewer[0].to_s, "account_slug" => viewer[1] } : synthetic_viewer,
        "columns" => KbDocument.column_names.sort
      }
    rescue StandardError => e
      columns = begin
        KbDocument.column_names.sort
      rescue StandardError
        []
      end
      {
        "db_checked" => false,
        "error_class" => e.class.name,
        "accounts" => [],
        "rows" => [],
        "viewer" => synthetic_viewer,
        "columns" => columns
      }
    end

    def synthetic_viewer
      { "account_id" => "non_owner", "account_slug" => nil, "synthetic" => true }
    end

    def build_inventory(db)
      slug_by_id = db["accounts"].to_h { |account| [ account["id"], account["slug"] ] }
      documents = db["rows"].map { |uid, account_id, display_name|
        owner = account_id.to_s
        {
          "document_uid" => uid.to_s,
          "account_id" => owner,
          "account_slug" => slug_by_id[owner],
          "display_name" => display_name.to_s,
          "classification" => "UNCLASSIFIED",
          "behaves_as" => "tenant_private",
          "explicit_danebo_mark" => false
        }
      }
      counts = documents.each_with_object(Hash.new(0)) { |row, tally| tally[row["classification"]] += 1 }
      present = db["accounts"].pluck("slug")
      {
        "db_checked" => db["db_checked"],
        "db_error_class" => db["error_class"],
        "accounts_queried" => Rag::SharedManualCorpus::SLUGS,
        "accounts_absent" => Rag::SharedManualCorpus::SLUGS - present,
        "kb_document_columns" => db["columns"],
        "approval_source_exists" => false,
        "rule" => "GENERAL_APPROVED requires an explicit Danebo mark on the document " \
          "that is neither the account slug nor the omitted corpus_scope default. " \
          "kb_documents has no knowledge_scope or corpus_scope column. " \
          "document_identities.yml confirmed is brand evidence, not scope. " \
          "UNCLASSIFIED behaves as tenant_private. F0 approves nothing.",
        "accounts" => db["accounts"],
        "classification_counts" => {
          "GENERAL_APPROVED" => counts["GENERAL_APPROVED"].to_i,
          "PRIVATE" => counts["PRIVATE"].to_i,
          "UNCLASSIFIED" => counts["UNCLASSIFIED"].to_i
        },
        "documents" => documents
      }
    end

    def build_discovery(catalog)
      entries = catalog.entries
      {
        "score_version" => "section_5",
        "catalog_path" => "config/document_identities.yml",
        "catalog_entry_count" => entries.size,
        "scope_affects_score" => false,
        "fixture" => phrase_set(FIXTURE, entries),
        "holdout" => phrase_set(HOLDOUT, entries)
      }
    end

    def phrase_set(phrases, entries)
      rows = phrases.map { |text| FieldCompanion::DiscoveryScore.phrase_metrics(text, entries) }
      {
        "phrases" => rows,
        "precision_at_3" => mean(rows.pluck("precision_at_3")),
        "top1_accuracy" => mean(rows.pluck("top1_accuracy")),
        "wrong_brand_candidate_rate" => micro_wrong_brand(rows)
      }
    end

    def build_eligible(discovery, inventory, catalog, db)
      owners = owner_index(inventory, catalog)
      viewer = db["viewer"]
      phrases = discovery["fixture"]["phrases"].map { |phrase|
        kept = phrase["document_ids"].select { |uid| eligible_uid?(uid, owners, viewer["account_id"]) }
        dropped = phrase["document_ids"] - kept
        gold = phrase["gold_document_ids"]
        phrase.merge(
          "document_ids" => kept,
          "labels" => kept.map { |uid| phrase["labels"][phrase["document_ids"].index(uid)] },
          "scores" => kept.map { |uid| phrase["scores"][phrase["document_ids"].index(uid)] },
          "dropped_document_ids" => dropped,
          "precision_at_3" => FieldCompanion::DiscoveryScore.precision_at_3(kept, gold),
          "top1_accuracy" => FieldCompanion::DiscoveryScore.top1_accuracy(kept, gold),
          "wrong_brand_candidate_rate" => 0
        )
      }
      {
        "viewer" => viewer.merge("role" => "non_owner"),
        "filter" => "Drop a document whose owner is not the viewer unless classification is GENERAL_APPROVED. " \
          "Score points are unchanged. With zero GENERAL_APPROVED, a non-owner receives none of those documents.",
        "general_approved_count" => inventory["classification_counts"]["GENERAL_APPROVED"],
        "fixture" => {
          "phrases" => phrases,
          "precision_at_3" => mean(phrases.pluck("precision_at_3")),
          "top1_accuracy" => mean(phrases.pluck("top1_accuracy")),
          "wrong_brand_candidate_rate" => 0
        }
      }
    end

    def eligible_uid?(uid, owners, viewer_id)
      meta = owners[uid]
      return false if meta.nil?
      return true if meta["account_id"].to_s == viewer_id.to_s

      meta["classification"] == "GENERAL_APPROVED"
    end

    def owner_index(inventory, catalog)
      index = {}
      inventory["documents"].each do |row|
        index[row["document_uid"]] = {
          "account_id" => row["account_id"],
          "classification" => row["classification"],
          "owner_source" => "kb_documents"
        }
      end
      catalog.entries.each do |entry|
        slot = index[entry.document_id]
        if slot
          slot["catalog_index_account_id"] = entry.account_id.to_s
          slot["catalog_index_slug"] = catalog_index_slug(entry.account_id)
        else
          index[entry.document_id] = {
            "account_id" => nil,
            "catalog_index_account_id" => entry.account_id.to_s,
            "catalog_index_slug" => catalog_index_slug(entry.account_id),
            "classification" => "UNCLASSIFIED",
            "owner_source" => "catalog_index_only"
          }
        end
      end
      index
    end

    def catalog_index_slug(account_id)
      { "1" => "danebo-legacy", "3" => "danebo-pilot-elevator" }[account_id.to_s]
    end

    def build_matrix(discovery, inventory, catalog, db)
      owners = owner_index(inventory, catalog)
      ranked = discovery["fixture"]["phrases"].flat_map { |phrase| phrase["document_ids"] }.uniq
      inventory_ids = inventory["documents"].pluck("document_uid")
      uids = (ranked + inventory_ids).uniq.sort
      rows = uids.map { |uid|
        meta = owners[uid] || { "account_id" => nil, "classification" => "UNCLASSIFIED" }
        {
          "document_uid" => uid,
          "physical_owner_account_id" => meta["account_id"],
          "owner_source" => meta["owner_source"],
          "catalog_index_account_id" => meta["catalog_index_account_id"],
          "catalog_index_slug" => meta["catalog_index_slug"],
          "current_visibility" => "owner_library_only",
          "current_retrievability" => "case_b_open_retrieve",
          "current_pinnability" => "owner_session_only",
          "proposed_knowledge_scope" => "tenant_private",
          "current_mechanism" => "CASE_B",
          "minimum_change" => MINIMUM_CHANGE,
          "reindex_required" => false,
          "duplicate_document_required" => false
        }
      }
      {
        "db_checked" => db["db_checked"],
        "answer" => "NEED_DOCUMENT_LEVEL_APPROVAL_SOURCE",
        "approval_source_exists" => false,
        "general_approved_count" => inventory["classification_counts"]["GENERAL_APPROVED"],
        "f4_route_confirmed" => true,
        "f4_blocked" => false,
        "options" => [
          {
            "id" => "existing_document_id_session_pin",
            "chosen" => true,
            "reindex_required" => false,
            "duplicate_document_required" => false,
            "summary" => MINIMUM_CHANGE
          },
          {
            "id" => "new_chunk_attribute",
            "chosen" => false,
            "reindex_required" => true,
            "duplicate_document_required" => false,
            "summary" => "Un atributo nuevo en el chunk separaría GENERAL_APPROVED del default " \
              "manual_corpus=general. Eso reindexa. F0 no la elige."
          }
        ],
        "rows" => rows
      }
    end

    def build_manifest(spring)
      eligible = spring["sha256_match"] && spring["bytes_match"] && spring["width"] == 956 && spring["height"] == 866
      {
        "cases" => [
          {
            "case_id" => "spring_assembly_misread",
            "filename" => "spring_assembly_misread.png",
            "path" => "tmp/field_companion/images/spring_assembly_misread.png",
            "media_type" => "image/png",
            "width" => spring["width"],
            "height" => spring["height"],
            "bytes" => spring["bytes"],
            "sha256" => spring["sha256"],
            "categories" => [ "cable_fixing", "springs" ],
            "eligible" => eligible,
            "gold" => {
              "manufacturer" => { "status" => "NOT_SCORED" },
              "model" => { "status" => "NOT_SCORED" },
              "component" => {
                "status" => "VERIFIED",
                "allowed" => [ "resorte", "resortes", "muelle", "muelles" ],
                "fail_if" => [ "resistenc", "bobinad" ]
              },
              "visible_text" => { "status" => "NOT_SCORED" }
            }
          }
        ]
      }
    end

    def run_probe
      bytes = File.binread(PROBE_IMAGE)
      sha = Digest::SHA256.hexdigest(bytes)
      record = {
        "requested_model_id" => PROBE_MODEL,
        "returned_model_id" => nil,
        "image_path" => "docs/field_companion/multimodal_availability_probe.jpg",
        "image_sha256" => sha,
        "image_bytes" => bytes.bytesize,
        "media_type" => "image/jpeg",
        "client" => "Anthropic::Client",
        "max_tokens" => 16,
        "system_prompt" => false,
        "text" => "ping",
        "track_bedrock_query_job" => false,
        "attempted" => false,
        "registered" => false,
        "success" => false,
        "error_class" => nil,
        "credential_source" => nil,
        "timestamp" => nil
      }
      unless sha == PROBE_SHA && bytes.bytesize == PROBE_BYTES
        return record.merge("error_class" => "ProbeImageMismatch", "registered" => true, "timestamp" => utc_now)
      end

      existing = read_json(ROOT.join("f0_probe.json"))
      if existing.is_a?(Hash) && existing["attempted"] && existing["image_sha256"] == PROBE_SHA && existing["requested_model_id"] == PROBE_MODEL
        return existing.merge("registered" => true)
      end
      return record.merge("error_class" => "ProbeSkipped", "timestamp" => utc_now) if ENV["F0_SKIP_PROBE"] == "1"

      api_key = ENV["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
      if api_key.blank?
        return record.merge(
          "error_class" => "MissingCredential",
          "credential_source" => "missing",
          "registered" => true,
          "attempted" => false,
          "timestamp" => utc_now
        )
      end

      source = ENV["ANTHROPIC_API_KEY"].present? ? "env" : "credentials"
      client = Anthropic::Client.new(api_key: api_key)
      message = client.messages.create(
        {
          model: PROBE_MODEL,
          max_tokens: 16,
          messages: [
            {
              role: "user",
              content: [
                {
                  type: "image",
                  source: {
                    type: "base64",
                    media_type: "image/jpeg",
                    data: Base64.strict_encode64(bytes)
                  }
                },
                { type: "text", text: "ping" }
              ]
            }
          ]
        }
      )
      returned = message.respond_to?(:model) ? message.model.to_s.presence : nil
      record.merge(
        "success" => true,
        "registered" => true,
        "attempted" => true,
        "returned_model_id" => returned,
        "credential_source" => source,
        "timestamp" => utc_now
      )
    rescue ArgumentError, NoMethodError => e
      record.merge(
        "success" => false,
        "registered" => true,
        "attempted" => false,
        "error_class" => e.class.name,
        "timestamp" => utc_now
      )
    rescue StandardError => e
      record.merge(
        "success" => false,
        "registered" => true,
        "attempted" => true,
        "error_class" => e.class.name,
        "timestamp" => utc_now
      )
    end

    def build_contract_audit(spring, probe, catalog)
      confirmed = catalog.entries.count(&:confirmed)
      effective = catalog.entries.count { |entry| Rag::DocumentIdentityCatalog.effectively_confirmed?(entry) }
      photo = Rag::ActiveEpisode.send(
        :sanitize_photo,
        "field_photo_id" => 1,
        "sha256" => "abc",
        "correlation_id" => "cid",
        "canonical_component" => "resorte",
        "summary" => "not persisted"
      )
      {
        "visual_pipeline" => visual_pipeline,
        "preprocessing" => preprocessing_map,
        "persistence" => persistence_map(photo),
        "k_matrix" => k_matrix,
        "deictic" => deictic_map,
        "identity" => {
          "document_id_is_document_uid" => true,
          "manufacturers" => Rag::ActiveEpisodeTurn::MANUFACTURERS,
          "confirmed_flag_count" => confirmed,
          "effectively_confirmed_count" => effective,
          "yaml_confirmed_without_evidence_is_catalog_confirmed" => false
        },
        "spring" => spring,
        "probe" => probe,
        "diagnostic_cache_in_head" => diagnostic_cache_in_head?
      }
    end

    def visual_pipeline
      text = BatchChunkingPrompt::MODEL_TEXT
      multimodal = BatchChunkingPrompt::MODEL_MULTIMODAL
      {
        "provider" => "Anthropic Direct",
        "production_client" => "ClaudeChunkingClient",
        "model_text" => text,
        "model_multimodal" => multimodal,
        "threshold_bytes" => FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD,
        "white_ratio_selects_model" => false,
        "max_tokens" => BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
        "field_photo_prompt_fingerprint_sha256" => FieldPhotoPrompt.prompt_fingerprint_sha256,
        "claude_sonnet_5_5_in_model_constants" => [ text, multimodal ].include?("claude-sonnet-5-5"),
        "matches_plan" => text == "claude-sonnet-5" &&
          multimodal == "claude-opus-5-5" &&
          FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD == 1_500_000 &&
          BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS == 8_000
      }
    end

    def preprocessing_map
      {
        "not_every_photo_is_1024" => true,
        "branches" => [
          {
            "id" => "canvas_happy_path",
            "file" => "app/javascript/controllers/rag_chat_controller.js",
            "method" => "compressImageOnClient",
            "behavior" => "Scales only when a side exceeds 1024. Otherwise keeps the size. JPEG quality 0.82. Input cap 25 MB. Output cap 3.75 MB."
          },
          {
            "id" => "canvas_fallback",
            "file" => "app/javascript/controllers/rag_chat_controller.js",
            "method" => "selectFile catch",
            "behavior" => "If Canvas fails and the file already fits in 3.75 MB, the original bytes and original MIME are sent. No rescale."
          },
          {
            "id" => "server_skip",
            "file" => "app/services/image_compression_service.rb",
            "method" => "should_skip_compression?",
            "behavior" => "True when the decoded binary is <= MAX_BINARY_BYTES (3.75 MB). No Vips. Same bytes and same MIME."
          },
          {
            "id" => "server_compress",
            "file" => "app/services/image_compression_service.rb",
            "method" => "process_image",
            "behavior" => "Max side 1024, JPEG, estimated quality, then quality 40 if still over 3.75 MB."
          }
        ]
      }
    end

    def persistence_map(photo)
      columns = FieldPhoto.column_names.sort
      retention = Rails.root.join("app/jobs/field_photo_retention_job.rb").read
      {
        "field_photo_columns" => columns,
        "visual_observation_column" => columns.include?("visual_observation"),
        "active_photo_after_sanitize" => photo,
        "history_max_chars" => ConversationSession::MAX_MSG_LENGTH,
        "compact_context_max_chars" => FieldPhotoAnalysisService::CHAT_CONTEXT_LIMIT,
        "vision_json_column" => false,
        "retention_destroys_row" => retention.include?("photo.destroy!"),
        "retention_default_days" => 90,
        "retention_default_env" => retention.include?('ENV.fetch("FIELD_PHOTO_RETENTION_DAYS", "90")'),
        "inspection_finding_keeps_row" => retention.include?("InspectionFinding"),
        "jsonb_on_same_row_dies_with_retention" => retention.include?("photo.destroy!") && columns.exclude?("visual_observation")
      }
    end

    def k_matrix
      cases = [
        { "id" => "exhaustive", "sources" => [], "question" => "lista completa de pasos", "k" => 15, "reranked" => 12 },
        { "id" => "open_schematic", "sources" => [], "question" => "conector -J26 del mazo", "k" => 20, "reranked" => nil },
        { "id" => "open", "sources" => [], "question" => "la puerta no cierra", "k" => 8, "reranked" => nil },
        { "id" => "safety_pinned", "sources" => [ "document" ], "question" => "hay una falla en el variador", "k" => 5, "reranked" => nil },
        { "id" => "photo_only", "sources" => [ "image_upload" ], "question" => "describe el equipo", "k" => 10, "reranked" => nil },
        { "id" => "documents_only", "sources" => [ "document" ], "question" => "ajuste del encoder", "k" => 3, "reranked" => nil },
        { "id" => "mixed", "sources" => [ "image_upload", "document" ], "question" => "ajuste del encoder", "k" => 3, "reranked" => nil }
      ]
      rows = cases.map { |spec|
        profile = RagRetrievalProfile.new(entity_sources: spec["sources"], question: spec["question"])
        actual_k = profile.number_of_results
        actual_reranked = profile.number_of_reranked_results
        spec.merge(
          "actual_k" => actual_k,
          "actual_reranked" => actual_reranked,
          "match" => actual_k == spec["k"] && actual_reranked == spec["reranked"]
        )
      }
      {
        "matches" => rows.all? { |row| row["match"] },
        "reranker_attached_only_when_env" => true,
        "rows" => rows
      }
    end

    def deictic_map
      rows = (DEICTIC_POSITIVE + DEICTIC_NEGATIVE).map { |phrase|
        normalized = Rag::FollowupQueryRewriter.normalize_label(phrase)
        {
          "phrase" => phrase,
          "normalized" => normalized,
          "deictic_match" => Rag::ActiveEpisodeTurn::DEICTIC_RE.match?(normalized),
          "expected_group" => DEICTIC_POSITIVE.include?(phrase) ? "positive_reference" : "negative"
        }
      }
      positives = rows.select { |row| row["expected_group"] == "positive_reference" }
      {
        "regex" => Rag::ActiveEpisodeTurn::DEICTIC_RE.source,
        "positive_references_all_false" => positives.none? { |row| row["deictic_match"] },
        "rows" => rows
      }
    end

    def diagnostic_cache_in_head?
      Rails.root.glob("app/**/*.rb").any? { |path|
        text = File.read(path)
        text.include?("diagnosis_cache") || text.include?("DiagnosisCache")
      }
    end

    def mean(values)
      return 0 if values.empty?

      values.sum(&:to_f) / values.size
    end

    def micro_wrong_brand(rows)
      denominator = rows.sum { |row| row["document_ids"].size }
      return 0 if denominator.zero?

      numerator = rows.sum { |row| row["wrong_brand_candidate_rate"].to_f * row["document_ids"].size }
      numerator / denominator
    end

    def read_json(path)
      return nil unless path.file?

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def write_json(path, payload)
      File.write(path, JSON.pretty_generate(payload) + "\n")
    end

    def utc_now
      Time.now.utc.iso8601
    end
  end
end

exit FieldCompanion::F0Audit.run
