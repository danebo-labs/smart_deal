# frozen_string_literal: true

require "application_system_test_case"

# Fase 5 end to end in a real browser on a phone-sized viewport, with Chrome's
# fake microphone standing in for the certifier. No provider is called: the
# job stays enqueued (test adapter) and the transcript is written the way
# TranscriptionJob would write it, so what is exercised is the UI contract —
# one control, upload-first, refresh from the database, autosave, explicit
# confirm, highlight + undo — and the connection-loss rehearsal the plan asks
# for (plan de septiembre, section 3.4).
class VoiceDictationCaptureTest < ApplicationSystemTestCase
  include Warden::Test::Helpers
  include ActiveJob::TestHelper

  # A distinct Capybara driver name is required: reset_sessions! reuses the
  # live Chrome, so a shared `:selenium` session keeps the first class's
  # launch flags (no fake mic) and any leftover CDP network_conditions.
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ],
            options: { name: :selenium_fake_mic } do |options|
    options.add_argument("--use-fake-ui-for-media-stream")
    options.add_argument("--use-fake-device-for-media-stream")
    options.add_argument("--autoplay-policy=no-user-gesture-required")
  end

  RECORD_BUTTON = "[data-action='voice-dictation#toggle']"
  STATUS = "[data-voice-dictation-target='status']"

  class FakeS3
    attr_reader :uploads

    def initialize
      @uploads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, bytes: data.bytesize, content_type: content_type }
      key
    end

    def delete_prefix(_prefix) = 1
  end

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @report = certification_reports(:torre_amunategui)
    # The fixture dictation (transcribed, unconfirmed) is on this report too:
    # its card on the page is the "reopen shows what's in progress" case, and
    # every count below excludes it.
    @fixture = voice_dictations(:cabina_dictado)
    @fake_s3 = FakeS3.new
    @orig_s3_new = S3DocumentsService.method(:new)
    fake = @fake_s3
    S3DocumentsService.define_singleton_method(:new) { |*_a, **_kw| fake }

    login_as users(:one), scope: :user
    visit certification_report_path(@report)
    assert_selector "#{RECORD_BUTTON}[data-state='idle']"
    grant_microphone
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    orig = @orig_s3_new
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
    Warden.test_reset!
  end

  test "dictate → upload on stop → transcript arrives → correct → confirm → highlighted finding with undo" do
    assert_selector STATUS, text: I18n.t("certifier.dictation.status.idle")
    assert_operator tap_height(RECORD_BUTTON), :>=, 72
    # Reopening shows the dictation still in progress from the fixture.
    assert_selector "#voice_dictation_#{@fixture.id}[data-status='transcribed']"

    record_for(1.6)

    # Upload-first: the card is on the page, in `pending`, before anything else.
    assert_selector "#voice_dictations li[data-status='pending']", text: I18n.t("certifier.dictation.card.transcribing")
    record = new_dictations.first
    assert_equal "pending", record.status
    assert_operator record.duration_seconds, :>=, 1
    assert_equal 1, @fake_s3.uploads.size
    assert_enqueued_jobs 1, only: TranscriptionJob
    assert_selector STATUS, text: I18n.t("certifier.dictation.status.idle"), wait: 5

    # The provider answers (as TranscriptionJob would write it); the browser
    # re-reads the card when it comes back to the foreground.
    transcribe!(record, "La puerta de cabina rosa en el marco al cerrar.")
    execute_script("document.dispatchEvent(new Event('visibilitychange'))")

    assert_selector "#voice_dictation_#{record.id}[data-status='transcribed']"
    textarea = find("#voice_dictation_#{record.id} textarea")
    assert_equal "La puerta de cabina rosa en el marco al cerrar.", textarea.value
    assert_operator tap_height("#voice_dictation_#{record.id} button[type='submit']:not([form])"), :>=, 72

    # Correction in one step, autosaved without any confirm.
    textarea.fill_in with: "La puerta de cabina roza en el marco al cerrar."
    assert_selector "#voice_dictation_#{record.id} [data-transcript-autosave-target='status']",
                    text: I18n.t("certifier.dictation.autosave.saved"), wait: 5
    assert_equal "La puerta de cabina roza en el marco al cerrar.", record.reload.transcript_edited
    assert_equal "transcribed", record.status
    assert_empty @report.inspection_findings.where(voice_dictation_id: record.id), "nothing in the draft before confirm"

    # Recovery (b): a reload keeps the correction in the panel.
    visit certification_report_path(@report)
    assert_equal "La puerta de cabina roza en el marco al cerrar.", find("#voice_dictation_#{record.id} textarea").value

    within("#voice_dictation_#{record.id}") do
      fill_in "voice_dictation[location]", with: "Embarque 3"
      click_on I18n.t("certifier.dictation.card.confirm")
    end

    assert_selector "li[data-highlighted-finding='true']", text: "La puerta de cabina roza en el marco al cerrar."
    finding = @report.inspection_findings.find_by!(voice_dictation_id: record.id)
    assert_equal "La puerta de cabina roza en el marco al cerrar.", finding.body
    assert_equal "Embarque 3", finding.location
    assert_selector "#inspection_finding_#{finding.id}[data-highlighted-finding='true']"
    assert_no_selector "#voice_dictation_#{record.id}"

    # Undo puts the text back in the panel — no re-recording.
    within("#inspection_finding_#{finding.id}") { click_on I18n.t("certifier.dictation.finding.undo") }
    assert_selector "#voice_dictation_#{record.id}[data-status='transcribed']"
    assert_equal "La puerta de cabina roza en el marco al cerrar.", find("#voice_dictation_#{record.id} textarea").value
    assert_not InspectionFinding.exists?(finding.id)
  end

  test "connection loss on stop keeps the recording and retries the upload when the network returns" do
    go_offline

    record_for(1.6)

    assert_selector "#{RECORD_BUTTON}[data-state='failed']", wait: 10
    assert_selector STATUS, text: I18n.t("certifier.dictation.status.upload_failed")
    assert_empty new_dictations
    assert_empty @fake_s3.uploads

    go_online
    execute_script("window.dispatchEvent(new Event('online'))")

    assert_selector "#voice_dictations li[data-status='pending']", wait: 10
    assert_equal 1, new_dictations.count
    assert_equal 1, @fake_s3.uploads.size
    assert_selector "#{RECORD_BUTTON}[data-state='idle']"
  end

  test "a glove double-tap is not uploaded and not billed" do
    # Two taps ~300ms apart, dispatched from the page so Selenium's own
    # round-trips don't stretch the gap past the 1s threshold.
    execute_script(<<~JS)
      const button = document.querySelector(#{RECORD_BUTTON.to_json})
      button.click()
      const stopWhenRecording = () => button.dataset.state === "recording" ? button.click() : setTimeout(stopWhenRecording, 50)
      setTimeout(stopWhenRecording, 300)
    JS

    assert_selector STATUS, text: I18n.t("certifier.dictation.status.too_short"), wait: 5
    assert_empty new_dictations
    assert_no_enqueued_jobs only: TranscriptionJob
    assert_selector STATUS, text: I18n.t("certifier.dictation.status.idle"), wait: 5
  end

  private

  def new_dictations
    @report.voice_dictations.where.not(id: @fixture.id).order(:created_at)
  end

  def record_for(seconds)
    find(RECORD_BUTTON).click
    assert_selector "#{RECORD_BUTTON}[data-state='recording']"
    assert_selector STATUS, text: /#{I18n.t("certifier.dictation.status.recording", time: "")}/
    sleep seconds
    find(RECORD_BUTTON).click
  end

  def transcribe!(record, text)
    claim = VoiceDictation.claim_for_transcription!(id: record.id, provider: "amazon_transcribe")
    assert claim
    assert VoiceDictation.record_transcript(id: record.id, claim_id: claim, text: text,
                                            provider: "amazon_transcribe", duration_seconds: 2)
  end

  def tap_height(selector)
    evaluate_script("document.querySelector(#{selector.to_json}).getBoundingClientRect().height")
  end

  def go_offline
    page.driver.browser.network_conditions = { offline: true, latency: 0, download_throughput: 0, upload_throughput: 0 }
  end

  def go_online
    # Setting offline: false with throughput -1 does not clear emulation on
    # current Chrome; the dedicated reset does.
    page.driver.browser.delete_network_conditions
  end

  def grant_microphone
    page.driver.browser.execute_cdp(
      "Browser.grantPermissions",
      origin: evaluate_script("window.location.origin"),
      permissions: [ "audioCapture" ]
    )
  end
end
