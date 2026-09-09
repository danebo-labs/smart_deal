# frozen_string_literal: true

require "test_helper"

# Fase 5 of docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md, the server
# half of the capture UI. What matters here is the contracts, not the markup:
# audio uploads the moment recording stops and is durable from then on (fixed
# rule 11); nothing reaches the draft without the editable panel and an
# explicit confirm (fixed rule 3); a double tap lands on one finding (fixed
# rule 13); and both isolation axes 404 (fixed rule 12).
class VoiceDictationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  class FakeS3
    attr_reader :uploads, :deleted_prefixes

    def initialize
      @uploads = []
      @deleted_prefixes = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, bytes: data.bytesize, content_type: content_type }
      key
    end

    def delete_prefix(prefix)
      @deleted_prefixes << prefix
      1
    end
  end

  TURBO_STREAM = "text/vnd.turbo-stream.html"

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @user    = users(:one)
    @account = accounts(:legacy)
    @report  = certification_reports(:torre_amunategui)
    @fake_s3 = FakeS3.new
    @orig_s3_new = S3DocumentsService.method(:new)
    fake = @fake_s3
    S3DocumentsService.define_singleton_method(:new) { |*_a, **_kw| fake }
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    orig = @orig_s3_new
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  def audio_upload(bytes = "OggS\x00\x02dictado-#{SecureRandom.hex(4)}".b)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "audio/webm", true, original_filename: "dictado.webm")
  end

  def upload_dictation(report = @report, duration: 42)
    post certification_report_voice_dictations_path(report),
         params: { audio: audio_upload, duration_seconds: duration },
         headers: { "Accept" => TURBO_STREAM }
  end

  def dictation(status: :transcribed, report: @report, user: @user, **attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: report.account, user: user, certification_report: report, sha256: sha,
        content_type: "audio/webm", status: status, provider: "amazon_transcribe",
        duration_seconds: 42, transcript_raw: "La puerta de cabina rosa en el marco al cerrar.",
        s3_key_audio: "voice_dictations/#{report.account_id}/#{sha}/audio.webm" }.merge(attrs)
    )
  end

  def other_user_in_legacy
    User.create!(email: "colleague-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @account)
  end

  def colleague_dictation(status: :transcribed)
    colleague = other_user_in_legacy
    report = CertificationReport.create!(account: @account, user: colleague, building_name: "De mi colega")
    dictation(status: status, report: report, user: colleague)
  end

  def edit_json(text)
    { params: { voice_dictation: { transcript_edited: text } }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" } }
  end

  # ── feature flag ────────────────────────────────────────────────────────

  test "every action responds 404 while the module flag is off" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in @user
    record = dictation

    upload_dictation
    assert_response :not_found
    get voice_dictation_path(record), headers: { "Accept" => TURBO_STREAM }
    assert_response :not_found
    patch voice_dictation_path(record), **edit_json("x")
    assert_response :not_found
    post confirm_voice_dictation_path(record)
    assert_response :not_found
  end

  # ── create: upload-first ────────────────────────────────────────────────

  test "uploading audio creates the dictation, stores the bytes and enqueues exactly one transcription" do
    sign_in @user

    record = nil
    assert_enqueued_jobs 1, only: TranscriptionJob do
      assert_difference -> { @report.voice_dictations.count }, 1 do
        upload_dictation(duration: 37)
      end
    end

    assert_response :success
    assert_equal TURBO_STREAM, response.media_type
    record = @report.voice_dictations.order(:created_at).last
    assert_equal "pending", record.status
    assert_equal @user.id, record.user_id
    assert_equal 37, record.duration_seconds, "the browser-measured duration feeds the cost estimate"
    assert record.s3_key_audio.end_with?("audio.webm")
    assert_equal 1, @fake_s3.uploads.size
    assert_match(/turbo-stream action="append" target="voice_dictations"/, response.body)
    assert_match(/id="voice_dictation_#{record.id}"/, response.body)
    assert_match(/data-status="pending"/, response.body)
  end

  test "re-sending the same blob after a flaky upload is the same dictation and no second billed call" do
    sign_in @user
    bytes = "OggS\x00\x02same-audio".b

    assert_enqueued_jobs 1, only: TranscriptionJob do
      2.times do
        post certification_report_voice_dictations_path(@report),
             params: { audio: audio_upload(bytes), duration_seconds: 20 },
             headers: { "Accept" => TURBO_STREAM }
        assert_response :success
      end
    end

    assert_equal 1, @report.voice_dictations.where(sha256: Digest::SHA256.hexdigest(bytes)).count
    assert_equal 1, @fake_s3.uploads.size
  end

  test "an upload with no audio is refused without creating anything" do
    sign_in @user

    assert_no_enqueued_jobs only: TranscriptionJob do
      assert_no_difference -> { VoiceDictation.count } do
        post certification_report_voice_dictations_path(@report), params: { duration_seconds: 5 },
             headers: { "Accept" => TURBO_STREAM }
      end
    end
    assert_response :unprocessable_entity
  end

  test "upload responds 404 for another user's report in the same account and for another account" do
    sign_in @user
    colleague_report = CertificationReport.create!(account: @account, user: other_user_in_legacy, building_name: "De mi colega")
    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")

    assert_no_difference -> { VoiceDictation.count } do
      upload_dictation(colleague_report)
      assert_response :not_found
      upload_dictation(other_report)
      assert_response :not_found
    end
  end

  # ── recovery route (a): reload after upload, before the result ──────────

  test "recovery (a): reloading the report after the upload shows the dictation with its state" do
    sign_in @user
    upload_dictation
    record = @report.voice_dictations.order(:created_at).last

    get certification_report_path(@report)

    assert_response :success
    assert_match(/id="voice_dictation_#{record.id}"/, response.body)
    assert_match(/data-status="pending"/, response.body)
    assert_match I18n.t("certifier.dictation.card.transcribing"), response.body
  end

  test "reopening a report shows transcribed and failed dictations with their state, never confirmed ones" do
    sign_in @user
    editable = voice_dictations(:cabina_dictado)
    failed   = dictation(status: :failed, failure_reason: "ProviderError: 429 insufficient_quota")
    done     = dictation(status: :confirmed, confirmed_at: Time.current, transcript_edited: "ya confirmado")

    get certification_report_path(@report)

    assert_response :success
    assert_match(/id="voice_dictation_#{editable.id}"[^>]*data-status="transcribed"/m, response.body)
    assert_match editable.transcript_raw, response.body
    assert_match(/id="voice_dictation_#{failed.id}"[^>]*data-status="failed"/m, response.body)
    assert_match "429 insufficient_quota", response.body
    assert_match retry_voice_dictation_path(failed), response.body
    assert_no_match(/id="voice_dictation_#{done.id}"/, response.body)
  end

  test "a failed dictation whose audio was purged offers no retry" do
    sign_in @user
    purged = dictation(status: :failed, audio_purged_at: Time.current, s3_key_audio: nil)

    get certification_report_path(@report)

    assert_no_match retry_voice_dictation_path(purged), response.body
    assert_match I18n.t("certifier.dictation.card.audio_gone"), response.body
  end

  # ── show: refresh from the database ─────────────────────────────────────

  test "show returns the card as a turbo stream replace with the full transcript" do
    sign_in @user
    record = dictation(transcript_raw: "x" * 3000)

    get voice_dictation_path(record), headers: { "Accept" => TURBO_STREAM }

    assert_response :success
    assert_match(/turbo-stream action="replace" target="voice_dictation_#{record.id}"/, response.body)
    assert_match "x" * 3000, response.body, "the panel reads the full text, not the 2000-char broadcast preview"
  end

  test "show removes the card of a dictation that was confirmed meanwhile" do
    sign_in @user
    record = dictation(status: :confirmed, confirmed_at: Time.current)

    get voice_dictation_path(record), headers: { "Accept" => TURBO_STREAM }

    assert_match(/turbo-stream action="remove" target="voice_dictation_#{record.id}"/, response.body)
  end

  test "show responds 404 on both isolation axes" do
    sign_in @user

    get voice_dictation_path(colleague_dictation), headers: { "Accept" => TURBO_STREAM }
    assert_response :not_found

    other_report = CertificationReport.create!(account: accounts(:climb), user: users(:two), building_name: "Otra cuenta")
    get voice_dictation_path(dictation(report: other_report, user: users(:two))), headers: { "Accept" => TURBO_STREAM }
    assert_response :not_found
  end

  # ── recovery route (b): autosave ────────────────────────────────────────

  test "recovery (b): an autosaved correction survives a reload" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    patch voice_dictation_path(record), **edit_json("La puerta de cabina del embarque tres ROZA en el marco al cerrar.")
    assert_response :no_content

    get certification_report_path(@report)
    assert_match "ROZA en el marco", response.body
    record.reload
    assert_equal "La puerta de cabina del embarque tres roza en el marco al cerrar.", record.transcript_raw
    assert_equal "transcribed", record.status
    assert_equal 0, @report.inspection_findings.where(voice_dictation_id: record.id).count,
                 "autosave never creates a finding — only confirm does (fixed rule 3)"
  end

  test "autosave is refused with 409 once the dictation is confirmed, leaving the frozen text intact" do
    sign_in @user
    record = dictation(status: :confirmed, confirmed_at: Time.current, transcript_edited: "congelado")

    patch voice_dictation_path(record), **edit_json("tardío")

    assert_response :conflict
    assert_equal "congelado", record.reload.transcript_edited
  end

  test "autosave responds 404 for a colleague's dictation and writes nothing" do
    sign_in @user
    record = colleague_dictation

    patch voice_dictation_path(record), **edit_json("hackeado")

    assert_response :not_found
    assert_nil record.reload.transcript_edited
  end

  # ── confirm: the only path into the draft ───────────────────────────────

  test "confirming commits the text on screen as a finding and highlights it with undo" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    assert_difference -> { @report.inspection_findings.count }, 1 do
      post confirm_voice_dictation_path(record),
           params: { voice_dictation: { transcript_edited: "Puerta de cabina roza en el marco (corregido al confirmar).",
                                        location: "Embarque 3" } }
    end

    finding = @report.inspection_findings.find_by!(voice_dictation_id: record.id)
    assert_equal "Puerta de cabina roza en el marco (corregido al confirmar).", finding.body
    assert_equal "Embarque 3", finding.location
    assert_nil finding.severity
    assert_redirected_to certification_report_path(@report, anchor: "inspection_finding_#{finding.id}")

    follow_redirect!
    assert_response :success
    assert_match(/id="inspection_finding_#{finding.id}"[^>]*data-highlighted-finding="true"/m, response.body)
    assert_match undo_voice_dictation_path(record), response.body
    assert_no_match(/id="voice_dictation_#{record.id}"/, response.body, "a confirmed dictation leaves the queue")

    # The highlight and its undo are for that one render only.
    get certification_report_path(@report)
    assert_no_match(/data-highlighted-finding/, response.body)
    assert_no_match undo_voice_dictation_path(record), response.body
  end

  # ── recovery route (c): double confirmation ─────────────────────────────

  test "recovery (c): a double tap on confirm yields one finding and the same redirect" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    assert_difference -> { InspectionFinding.count }, 1 do
      2.times do
        post confirm_voice_dictation_path(record),
             params: { voice_dictation: { transcript_edited: "Texto final." } }
        assert_response :redirect
      end
    end

    finding = InspectionFinding.find_by!(voice_dictation_id: record.id)
    assert_equal "Texto final.", finding.body
    assert_redirected_to certification_report_path(@report, anchor: "inspection_finding_#{finding.id}")
  end

  test "confirming without a text param commits the autosaved correction" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)
    patch voice_dictation_path(record), **edit_json("Autoguardado antes de confirmar.")

    post confirm_voice_dictation_path(record)

    assert_equal "Autoguardado antes de confirmar.", InspectionFinding.find_by!(voice_dictation_id: record.id).body
  end

  test "confirming an emptied panel is refused rather than silently committing the raw transcript" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    assert_no_difference -> { InspectionFinding.count } do
      post confirm_voice_dictation_path(record), params: { voice_dictation: { transcript_edited: "   " } }
    end

    assert_redirected_to certification_report_path(@report, anchor: "voice_dictation_#{record.id}")
    assert_equal I18n.t("certifier.dictation.alerts.empty"), flash[:alert]
    assert_equal "transcribed", record.reload.status
  end

  test "a dictation still transcribing cannot be confirmed" do
    sign_in @user
    record = dictation(status: :transcribing, transcript_raw: nil)

    assert_no_difference -> { InspectionFinding.count } do
      post confirm_voice_dictation_path(record)
    end
    assert_equal I18n.t("certifier.dictation.alerts.not_confirmable"), flash[:alert]
  end

  test "confirm responds 404 for a colleague's dictation and creates nothing" do
    sign_in @user
    record = colleague_dictation

    assert_no_difference -> { InspectionFinding.count } do
      post confirm_voice_dictation_path(record)
    end
    assert_response :not_found
  end

  # ── undo ────────────────────────────────────────────────────────────────

  test "undo removes the finding and returns the text to the editable panel" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)
    post confirm_voice_dictation_path(record), params: { voice_dictation: { transcript_edited: "Confirmado por error." } }

    assert_difference -> { InspectionFinding.count }, -1 do
      post undo_voice_dictation_path(record)
    end

    assert_redirected_to certification_report_path(@report, anchor: "voice_dictation_#{record.id}")
    follow_redirect!
    assert_match(/id="voice_dictation_#{record.id}"[^>]*data-status="transcribed"/m, response.body)
    assert_match "Confirmado por error.", response.body, "undo never costs the correction"
  end

  test "undo on a dictation that was never confirmed changes nothing" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    post undo_voice_dictation_path(record)

    assert_equal I18n.t("certifier.dictation.alerts.nothing_to_undo"), flash[:alert]
    assert_equal "transcribed", record.reload.status
  end

  test "undo responds 404 for a colleague's dictation" do
    sign_in @user
    record = colleague_dictation
    VoiceDictationConfirmation.call(record)

    assert_no_difference -> { InspectionFinding.count } do
      post undo_voice_dictation_path(record)
    end
    assert_response :not_found
  end

  # ── retry (T5) ──────────────────────────────────────────────────────────

  test "retry reopens a failed dictation and enqueues one transcription" do
    sign_in @user
    record = dictation(status: :failed, failure_reason: "ProviderError: 429")

    assert_enqueued_jobs 1, only: TranscriptionJob do
      post retry_voice_dictation_path(record)
    end

    assert_redirected_to certification_report_path(@report, anchor: "voice_dictation_#{record.id}")
    assert_equal "pending", record.reload.status
  end

  test "retry is refused once the audio is gone" do
    sign_in @user
    record = dictation(status: :failed, audio_purged_at: Time.current, s3_key_audio: nil)

    assert_no_enqueued_jobs only: TranscriptionJob do
      post retry_voice_dictation_path(record)
    end
    assert_equal I18n.t("certifier.dictation.alerts.cannot_retry"), flash[:alert]
  end

  test "retry responds 404 for a colleague's dictation" do
    sign_in @user

    assert_no_enqueued_jobs only: TranscriptionJob do
      post retry_voice_dictation_path(colleague_dictation(status: :failed))
    end
    assert_response :not_found
  end

  # ── destroy (discard) ───────────────────────────────────────────────────

  test "discarding an unconfirmed dictation destroys the row and its audio" do
    sign_in @user
    record = dictation

    assert_difference -> { VoiceDictation.count }, -1 do
      delete voice_dictation_path(record)
    end

    assert_redirected_to certification_report_path(@report, anchor: "voice_dictation_#{record.id}")
    assert_equal [ "voice_dictations/#{@account.id}/#{record.sha256}/" ], @fake_s3.deleted_prefixes
  end

  test "a confirmed dictation is the finding's trace and cannot be discarded" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)
    VoiceDictationConfirmation.call(record)

    assert_no_difference -> { VoiceDictation.count } do
      delete voice_dictation_path(record)
    end
    assert_equal I18n.t("certifier.dictation.alerts.cannot_discard"), flash[:alert]
  end

  test "discard responds 404 for a colleague's dictation" do
    sign_in @user
    record = colleague_dictation

    assert_no_difference -> { VoiceDictation.count } do
      delete voice_dictation_path(record)
    end
    assert_response :not_found
  end

  # ── the capture UI itself ───────────────────────────────────────────────

  test "the report page renders the single record control with the plan's tap targets" do
    sign_in @user

    get certification_report_path(@report)

    assert_response :success
    assert_match(/data-controller="voice-dictation"/, response.body)
    assert_match(/data-voice-dictation-upload-url-value="#{Regexp.escape(certification_report_voice_dictations_path(@report))}"/, response.body)
    assert_match(/data-voice-dictation-show-url-template-value="\/voice_dictations\/:id"/, response.body)
    assert_match(/data-action="voice-dictation#toggle"[^>]*class="[^"]*min-h-\[72px\] min-w-\[72px\]/m, response.body)
    assert_equal 1, response.body.scan('data-action="voice-dictation#toggle"').size, "exactly one record/stop control"
    assert_match(/data-voice-dictation-target="status"/, response.body)
    # The typed form stays as the permanent fallback.
    assert_match certification_report_inspection_findings_path(@report), response.body
  end

  test "the editable panel meets the tap target figures and mounts the autosave" do
    sign_in @user
    record = voice_dictations(:cabina_dictado)

    get certification_report_path(@report)

    card = response.body[/<li id="voice_dictation_#{record.id}".*?<\/li>/m]
    assert card, "the transcribed dictation's card is on the page"
    assert_match(/data-controller="transcript-autosave"/, card)
    assert_match(/data-transcript-autosave-url-value="#{Regexp.escape(voice_dictation_path(record))}"/, card)
    assert_match(/action="#{Regexp.escape(confirm_voice_dictation_path(record))}"/, card)
    assert_match(/min-h-\[72px\]/, card, "confirm is the primary action")
    assert_match(/min-h-\[60px\]/, card)
    assert_match(/gap-4/, card, "16px between adjacent controls")
    assert_match(/data-turbo-confirm=/, card, "discarding audio asks first")
  end
end
