# frozen_string_literal: true

require "test_helper"

class FieldPhotoDiagnosisCacheTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @sha = Digest::SHA256.hexdigest("same-photo")
  end

  teardown do
    Rails.cache = @previous_cache
    ENV.delete("PHOTO_DIAGNOSIS_CACHE_TTL_HOURS")
  end

  test "key includes contract, account, digest, and locale" do
    key = FieldPhotoDiagnosisCache.key(account_id: 7, sha256: @sha, locale: "es")

    assert_equal "photo_dx/#{FieldPhotoPrompt::CONTRACT_VERSION}/7/#{@sha}/es", key
  end

  test "same digest hits only within the same account" do
    assert FieldPhotoDiagnosisCache.write(account_id: 1, sha256: @sha, locale: "es", value: payload)

    assert_equal "Panel", FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")[:canonical_name]
    assert_nil FieldPhotoDiagnosisCache.read(account_id: 2, sha256: @sha, locale: "es")
  end

  test "corrupt payload is invalidated and treated as a miss" do
    key = FieldPhotoDiagnosisCache.key(account_id: 1, sha256: @sha, locale: "es")
    Rails.cache.write(key, { analysis: "contains binary", binary: "raw" })

    assert_nil FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")
    assert_nil Rails.cache.read(key)
  end

  test "ttl zero disables reads and writes" do
    ENV["PHOTO_DIAGNOSIS_CACHE_TTL_HOURS"] = "0"

    assert_not FieldPhotoDiagnosisCache.write(account_id: 1, sha256: @sha, locale: "es", value: payload)
    assert_nil FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")
  end

  test "expired entries miss" do
    key = FieldPhotoDiagnosisCache.key(account_id: 1, sha256: @sha, locale: "es")
    Rails.cache.write(key, payload, expires_in: 0.001)
    sleep 0.01

    assert_nil FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")
  end

  test "cache failures degrade to misses" do
    failing_cache = Object.new
    failing_cache.define_singleton_method(:read) { |_key| raise "down" }
    failing_cache.define_singleton_method(:delete) { |_key| raise "down" }
    Rails.cache = failing_cache

    assert_nil FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")
  end

  test "stored schema contains cost but never image bytes" do
    FieldPhotoDiagnosisCache.write(
      account_id: 1,
      sha256: @sha,
      locale: "es",
      value: payload.merge(binary: "raw", data: Base64.strict_encode64("raw"))
    )

    stored = FieldPhotoDiagnosisCache.read(account_id: 1, sha256: @sha, locale: "es")
    assert_operator stored[:original_cost], :>, 0
    assert_nil stored[:binary]
    assert_nil stored[:data]
  end

  private

  def payload
    {
      analysis: "Observed",
      compact_context: "[FOTO] Panel",
      canonical_name: "Panel",
      aliases: [ "P1" ],
      manufacturer: "UNKNOWN",
      model_visible: "P1",
      condition: "GOOD",
      visible_codes: [ "P1" ],
      model_id: "claude-sonnet-4-6-direct",
      input_tokens: 100,
      output_tokens: 50,
      original_cost: 0.00105,
      latency_ms: 200,
      created_at: Time.current.iso8601,
      contract_version: FieldPhotoPrompt::CONTRACT_VERSION
    }
  end
end
