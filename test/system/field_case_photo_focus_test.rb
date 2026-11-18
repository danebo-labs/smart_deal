# frozen_string_literal: true

require "application_system_test_case"

class FieldCasePhotoFocusTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  teardown { Warden.test_reset! }

  test "the manual stays selected when a photo opens a case and the page is reopened" do
    user = users(:one)
    manual = KbDocument.create!(account: user.account, display_name: "THYSSEN (Manual de Maniobra Universal con MCINV4)",
                                s3_key: "uploads/thyssen-mcinv4.pdf", aliases: [])
    card = %(.kb-doc-btn[data-doc-id="#{manual.id}"])
    question = "Estoy con un Thyssen FDN Universal con MCINV4. El ascensor quedó detenido y el display marca EA"

    storage = Object.new
    storage.define_singleton_method(:upload_binary) { |*| true }
    preview = Object.new
    preview.define_singleton_method(:call) { |_| nil }
    preview.define_singleton_method(:trusted_redirect_url?) { |_| false }
    original_storage = S3DocumentsService.method(:new)
    original_preview = FieldPhotoUrlService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { |*| storage }
    FieldPhotoUrlService.define_singleton_method(:new) { |**| preview }

    login_as user, scope: :user
    page.current_window.resize_to(430, 800)
    visit root_path
    find("button[role='tab']", text: "Archivos").click
    find("#{card}[data-selected='false']").click
    assert_selector "#{card}[data-selected='true']"
    find("button[role='tab']", text: "Chat").click
    attach_file Rails.root.join("docs/field_companion/multimodal_availability_probe.jpg"), make_visible: true
    assert_text "multimodal_availability_probe.jpg"
    find("[data-rag-chat-target='input']").set(question)
    find(".chat-composer-form button[type='submit']").click

    assert_current_path(/\?caso=\d+/)
    assert_text question
    find("button[role='tab']", text: "Archivos").click
    assert_selector "#{card}[data-selected='true']"

    visit current_url
    assert_text question
    find("button[role='tab']", text: "Archivos").click
    assert_selector "#{card}[data-selected='true']"
  ensure
    S3DocumentsService.define_singleton_method(:new, original_storage) if original_storage
    FieldPhotoUrlService.define_singleton_method(:new, original_preview) if original_preview
  end
end
