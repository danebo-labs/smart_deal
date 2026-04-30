# frozen_string_literal: true

require "test_helper"

class ProcessWhatsappMediaJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  # ─── Helpers ─────────────────────────────────────────────────────────────────

  def stub_twilio_client
    sent = []
    messages_resource = Object.new
    messages_resource.define_singleton_method(:create) { |**kwargs| sent << kwargs }
    client = Object.new
    client.define_singleton_method(:messages) { messages_resource }
    original_new = Twilio::REST::Client.method(:new)
    Twilio::REST::Client.define_singleton_method(:new) { |*_a| client }
    yield sent
  ensure
    Twilio::REST::Client.define_singleton_method(:new) { |*a| original_new.call(*a) }
  end

  def with_env(vars)
    original = {}
    vars.each_key { |k| original[k] = ENV[k.to_s] }
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    vars.each_key { |k| original[k].nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = original[k] }
  end

  def stub_image_download(content: "fake-image-data")
    original = URI.method(:parse)
    URI.define_singleton_method(:parse) do |url|
      io = StringIO.new(content)
      def io.open(*_args)
        yield(self) if block_given?
        self
      end
      def io.read; string; end
      io
    end
    yield
  ensure
    URI.define_singleton_method(:parse) { |url| original.call(url) }
  end

  def stub_image_compression(media_type: "image/jpeg")
    original = ImageCompressionService.method(:compress)
    ImageCompressionService.define_singleton_method(:compress) do |data, _type|
      { data: data, media_type: media_type, binary: Base64.decode64(data) }
    end
    yield
  ensure
    ImageCompressionService.define_singleton_method(:compress) { |*a| original.call(*a) }
  end

  def stub_s3_upload(key: "uploads/2026-04-15/wa_20260415_120000_0.jpeg")
    original = S3DocumentsService.method(:new)
    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) { |*_args| key }
    S3DocumentsService.define_singleton_method(:new) { |**_kwargs| fake_s3 }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) }
  end

  def stub_kb_sync(job_id: "JOB-123", kb_id: "KB-1", data_source_id: "DS-1")
    original = KbSyncService.method(:new)
    fake = Object.new
    fake.define_singleton_method(:sync!) { |**_kwargs| { job_id: job_id, kb_id: kb_id, data_source_id: data_source_id } }
    KbSyncService.define_singleton_method(:new) { |**_kwargs| fake }
    yield
  ensure
    KbSyncService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) }
  end

  def stub_kb_sync_conflict
    original = KbSyncService.method(:new)
    fake = Object.new
    fake.define_singleton_method(:sync!) { |**_kwargs| raise Aws::BedrockAgent::Errors::ConflictException.new(nil, "ongoing ingestion") }
    KbSyncService.define_singleton_method(:new) { |**_kwargs| fake }
    yield
  ensure
    KbSyncService.define_singleton_method(:new) { |**kwargs| original.call(**kwargs) }
  end

  MEDIA = [ { url: "https://api.twilio.com/fake/media/1", content_type: "image/jpeg" } ].freeze
  JOB_ARGS = { from: "whatsapp:+1999", to: "whatsapp:+14155238886", body: "", media: MEDIA,
               message_sid: "MM_test", conv_session_id: nil }.freeze

  # ─── Successful path ──────────────────────────────────────────────────────────

  test "enqueues BedrockIngestionJob after successful S3 upload and sync" do
    with_env("TWILIO_ACCOUNT_SID" => "ACtest", "TWILIO_AUTH_TOKEN" => "tok") do
      stub_image_download do
        stub_image_compression do
          stub_s3_upload do
            stub_kb_sync do
              assert_enqueued_with(job: BedrockIngestionJob) do
                ProcessWhatsappMediaJob.perform_now(**JOB_ARGS)
              end
            end
          end
        end
      end
    end
  end

  # ─── Download failure ─────────────────────────────────────────────────────────

  test "sends failure notification when no images can be downloaded after retries exhaust" do
    original_parse = URI.method(:parse)
    # Only fail Twilio media fetch URLs; Twilio REST client still uses URI.parse internally.
    URI.define_singleton_method(:parse) do |url|
      if url.to_s.include?("api.twilio.com/fake/media")
        raise SocketError, "connection refused"
      else
        original_parse.call(url)
      end
    end

    with_env("TWILIO_ACCOUNT_SID" => "ACtest", "TWILIO_AUTH_TOKEN" => "tok") do
      stub_twilio_client do |sent|
        perform_enqueued_jobs do
          ProcessWhatsappMediaJob.perform_later(**JOB_ARGS)
        end
        assert_equal 1, sent.size
        assert_equal I18n.t("rag.whatsapp_indexing_failed"), sent.first[:body]
        assert_equal "whatsapp:+14155238886", sent.first[:from]
        assert_equal "whatsapp:+1999", sent.first[:to]
      end
    end
  ensure
    URI.define_singleton_method(:parse) { |url| original_parse.call(url) }
  end

  # ─── ConflictException does NOT send immediate notification (it retries) ────────

  test "ConflictException on first attempt enqueues retry, does not notify user yet" do
    with_env("TWILIO_ACCOUNT_SID" => "ACtest", "TWILIO_AUTH_TOKEN" => "tok") do
      stub_twilio_client do |sent|
        stub_image_download do
          stub_image_compression do
            stub_s3_upload do
              stub_kb_sync_conflict do
                # First attempt: ConflictException → retry enqueued, no WhatsApp sent.
                assert_enqueued_jobs 1, only: ProcessWhatsappMediaJob do
                  ProcessWhatsappMediaJob.perform_now(**JOB_ARGS)
                end
                assert_empty sent, "Should not notify user on first ConflictException — it retries"
              end
            end
          end
        end
      end
    end
  end

  # ─── Locale key contract: each failure type maps to its own key ───────────────

  test "whatsapp_indexing_conflict locale key exists and differs from generic failure key" do
    conflict_msg = I18n.t("rag.whatsapp_indexing_conflict")
    generic_msg  = I18n.t("rag.whatsapp_indexing_failed")

    assert conflict_msg.present?, "rag.whatsapp_indexing_conflict must be defined"
    assert generic_msg.present?,  "rag.whatsapp_indexing_failed must be defined"
    assert_not_equal conflict_msg, generic_msg, "Conflict and generic failure messages must be distinct"
    assert_includes conflict_msg, "⚠️"
    assert_includes generic_msg,  "⚠️"
  end

  test "CONFLICT_ATTEMPTS is greater than MAX_ATTEMPTS" do
    assert ProcessWhatsappMediaJob::CONFLICT_ATTEMPTS > ProcessWhatsappMediaJob::MAX_ATTEMPTS,
           "ConflictException retry window must exceed generic retry window"
  end
end
