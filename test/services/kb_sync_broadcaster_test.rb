# frozen_string_literal: true

require "test_helper"

class KbSyncBroadcasterTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test ".failed broadcasts with default Spanish message when no locale given" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.failed(filenames: [ "doc.txt" ], reason: "error")
    end
    assert_equal 1, messages.size
    assert_equal "failed", messages.first["status"]
    assert_equal I18n.t("rag.document_indexing_failed_message", locale: :es), messages.first["message"]
  end

  test ".failed broadcasts Spanish message when locale='es'" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.failed(filenames: [ "doc.txt" ], reason: "error", locale: "es")
    end
    assert_equal I18n.t("rag.document_indexing_failed_message", locale: :es), messages.first["message"]
  end

  test ".failed broadcasts English message when locale='en'" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.failed(filenames: [ "doc.txt" ], reason: "error", locale: "en")
    end
    assert_equal I18n.t("rag.document_indexing_failed_message", locale: :en), messages.first["message"]
  end

  test ".failed uses explicit message arg regardless of locale" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.failed(filenames: [ "doc.txt" ], reason: "error",
                               message: "Custom error", locale: "en")
    end
    assert_equal "Custom error", messages.first["message"]
  end

  test ".retrying broadcasts Spanish message when locale='es'" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.retrying(filenames: [ "doc.txt" ], attempt: 1, delay: 5, locale: "es")
    end
    assert_equal "retrying", messages.first["status"]
    assert_equal I18n.t("rag.upload_retrying_aurora", locale: :es), messages.first["message"]
  end

  test ".retrying broadcasts English message when locale='en'" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.retrying(filenames: [ "doc.txt" ], attempt: 1, delay: 5, locale: "en")
    end
    assert_equal I18n.t("rag.upload_retrying_aurora", locale: :en), messages.first["message"]
  end

  test ".retrying defaults to Spanish when no locale given" do
    messages = capture_broadcasts("kb_sync") do
      KbSyncBroadcaster.retrying(filenames: [ "doc.txt" ], attempt: 1, delay: 5)
    end
    assert_equal I18n.t("rag.upload_retrying_aurora", locale: :es), messages.first["message"]
  end
end
