# frozen_string_literal: true

require "test_helper"

# "Datos de la certificadora": one issuer identity per company (a company is an
# account), writable only by its designated owner, readable by every colleague.
class CertifierSettingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  class FakeS3
    attr_reader :uploads

    def initialize
      @uploads = []
    end

    def upload_binary(key, data, content_type)
      @uploads << { key: key, data: data, content_type: content_type }
      key
    end
  end

  def with_fake_s3(fake)
    orig = S3DocumentsService.method(:new)
    S3DocumentsService.define_singleton_method(:new) { fake }
    yield
  ensure
    S3DocumentsService.define_singleton_method(:new) { |*a, **kw| orig.call(*a, **kw) }
  end

  # Each company answers on its own host (AccountHosts), and
  # ensure_user_belongs_to_host_account! rejects a user signed in against
  # someone else's host. Tests state the host explicitly so the tenant seam is
  # exercised rather than bypassed.
  CLIMB_HOST  = "ascensoresclimb.localhost"
  LEGACY_HOST = "www.example.com"

  setup do
    ENV["CERTIFIER_MODULE_ENABLED"] = "true"
    @configured  = accounts(:climb)
    @owner       = users(:two)
    @legacy      = accounts(:legacy)
    @legacy_user = users(:one)
  end

  teardown do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
  end

  def sign_in_climb(user)
    host! CLIMB_HOST
    sign_in user
  end

  def sign_in_legacy(user)
    host! LEGACY_HOST
    sign_in user
  end

  # Same shape as FieldPhotosControllerTest: swap the presigner's result so the
  # trusted-host check is exercised without reaching AWS.
  def with_fake_logo_url(url)
    original = CertifierLogoUrlService.instance_method(:call)
    CertifierLogoUrlService.define_method(:call) { |*_args| url }
    yield
  ensure
    CertifierLogoUrlService.define_method(:call, original)
  end

  def colleague_of(account)
    User.create!(email: "colleague-#{SecureRandom.hex(4)}@example.com", password: "password123", account: account)
  end

  def logo_upload
    fixture_file_upload("tiny.png", "image/png")
  end

  # ── Guards ─────────────────────────────────────────────────────────────────

  test "responds 404 when the module flag is disabled" do
    ENV.delete("CERTIFIER_MODULE_ENABLED")
    sign_in_climb @owner

    get certifier_settings_path
    assert_response :not_found
  end

  test "redirects an unauthenticated visitor to login" do
    get certifier_settings_path
    assert_response :redirect
  end

  # ── show: the owner edits, the company reads ───────────────────────────────

  test "the designated owner sees the editable form" do
    sign_in_climb @owner

    get certifier_settings_path

    assert_response :success
    assert_match @configured.certifier_name, response.body
    assert_match(/name="account\[certifier_name\]"/, response.body)
  end

  # Read-only is not a 404: seeing the header that will appear on your own report
  # is legitimate for any colleague of the company.
  test "a colleague of the same company reads the data without a form" do
    sign_in_climb colleague_of(@configured)

    get certifier_settings_path

    assert_response :success
    assert_match @configured.certifier_name, response.body
    assert_no_match(/name="account\[certifier_name\]"/, response.body)
    assert_match I18n.t("certifier.settings.read_only"), response.body
  end

  test "an account with no designated owner is read-only for everyone" do
    sign_in_legacy @legacy_user

    get certifier_settings_path

    assert_response :success
    assert_match I18n.t("certifier.settings.no_manager"), response.body
    assert_no_match(/name="account\[certifier_name\]"/, response.body)
  end

  # Old accounts predate this configuration: an empty header must render, not 500.
  test "an unconfigured account renders with the missing data called out" do
    sign_in_legacy @legacy_user

    get certifier_settings_path

    assert_response :success
    assert_match I18n.t("certifier.settings.name_missing"), response.body
    assert_match I18n.t("certifier.settings.incomplete_notice"), response.body
  end

  # ── Isolation: a company only ever sees its own identity ───────────────────

  test "each company sees only its own data" do
    sign_in_legacy @legacy_user
    get certifier_settings_path
    assert_response :success
    assert_no_match(/Ascensores Climb Ltda\./, response.body)

    sign_out @legacy_user
    sign_in_climb @owner
    get certifier_settings_path
    assert_response :success
    assert_match(/Ascensores Climb Ltda\./, response.body)
  end

  # The host is the tenant boundary: a user signed in against another company's
  # host never reaches that company's configuration.
  test "a user cannot reach another company's settings through its host" do
    host! CLIMB_HOST
    sign_in @legacy_user

    get certifier_settings_path

    assert_response :redirect
    assert_no_match(/Ascensores Climb Ltda\./, response.body.to_s)
  end

  # ── update ─────────────────────────────────────────────────────────────────

  test "the owner updates the name and the MINVU role" do
    sign_in_climb @owner

    patch certifier_settings_path, params: { account: { certifier_name: "Nueva Certificadora SpA", certifier_minvu_role: "099" } }

    assert_redirected_to certifier_settings_path
    @configured.reload
    assert_equal "Nueva Certificadora SpA", @configured.certifier_name
    assert_equal "099", @configured.certifier_minvu_role
  end

  test "a colleague cannot update the company identity" do
    sign_in_climb colleague_of(@configured)

    patch certifier_settings_path, params: { account: { certifier_name: "Secuestrada SpA" } }

    assert_redirected_to certifier_settings_path
    assert_equal I18n.t("certifier.settings.alerts.not_manager"), flash[:alert]
    assert_equal "Ascensores Climb Ltda.", @configured.reload.certifier_name
  end

  test "a user of an account with no owner cannot update it" do
    sign_in_legacy @legacy_user

    patch certifier_settings_path, params: { account: { certifier_name: "Me la apropio" } }

    assert_redirected_to certifier_settings_path
    assert_nil @legacy.reload.certifier_name
  end

  # An account only ever writes its own row: current_account is the scope, so a
  # forged id in the payload is not even a parameter the controller accepts.
  test "the account id is not settable from the payload" do
    sign_in_climb @owner

    patch certifier_settings_path, params: { account: { id: @legacy.id, certifier_name: "Cruzada" } }

    assert_redirected_to certifier_settings_path
    assert_equal "Cruzada", @configured.reload.certifier_name
    assert_nil @legacy.reload.certifier_name
  end

  # ── Logo ───────────────────────────────────────────────────────────────────

  test "the owner uploads a logo and its metadata is persisted together" do
    sign_in_climb @owner
    fake = FakeS3.new

    with_fake_s3(fake) do
      patch certifier_settings_path, params: { account: { certifier_name: "Ascensores Climb Ltda.", certifier_logo: logo_upload } }
    end

    assert_redirected_to certifier_settings_path
    @configured.reload
    assert_equal 1, fake.uploads.size
    assert_equal fake.uploads.first[:key], @configured.certifier_logo_s3_key
    assert_equal "image/png", @configured.certifier_logo_content_type
    assert_equal Digest::SHA256.hexdigest(fake.uploads.first[:data]), @configured.certifier_logo_sha256
    assert_operator @configured.certifier_logo_byte_size, :>, 0
  end

  # A rejected logo must leave the account exactly as it was: the previous logo
  # keeps working and the accompanying text fields are not half-saved either.
  test "a rejected logo keeps the previous one and does not touch the other fields" do
    sign_in_climb @owner
    before = @configured.attributes.slice(*%w[certifier_logo_s3_key certifier_logo_sha256 certifier_name])
    fake = FakeS3.new

    with_fake_s3(fake) do
      patch certifier_settings_path, params: {
        account: { certifier_name: "No debe guardarse", certifier_logo: fixture_file_upload("sample.txt", "image/png") }
      }
    end

    assert_response :unprocessable_entity
    assert_empty fake.uploads
    assert_equal before, @configured.reload.attributes.slice(*before.keys)
    assert_match I18n.t("certifier.settings.logo_errors.unsupported_format"), response.body
  end

  test "removing the logo clears the reference without deleting the stored object" do
    sign_in_climb @owner
    key = @configured.certifier_logo_s3_key

    delete logo_certifier_settings_path

    assert_redirected_to certifier_settings_path
    @configured.reload
    assert_nil @configured.certifier_logo_s3_key
    assert_nil @configured.certifier_logo_sha256
    assert key.present?, "the S3 object is intentionally left in place for already generated exports"
  end

  test "a colleague cannot remove the logo" do
    sign_in_climb colleague_of(@configured)

    delete logo_certifier_settings_path

    assert_redirected_to certifier_settings_path
    assert @configured.reload.certifier_logo?
  end

  # ── Serving the logo ───────────────────────────────────────────────────────

  test "the logo endpoint redirects to a presigned URL of our own bucket" do
    sign_in_climb @owner
    bucket = S3DocumentsService.new.bucket_name
    signed = "https://#{bucket}.s3.amazonaws.com/#{@configured.certifier_logo_s3_key}?X-Amz-Signature=abc"

    with_fake_logo_url(signed) { get logo_certifier_settings_path }

    assert_response :redirect
    assert_equal signed, response.headers["Location"]
  end

  # No open redirect: an untrusted host is a 404, never a redirect.
  test "the logo endpoint refuses a URL outside our bucket" do
    sign_in_climb @owner

    with_fake_logo_url("https://evil.example.com/logo.png") { get logo_certifier_settings_path }

    assert_response :not_found
  end

  test "the logo endpoint is 404 when the company has no logo" do
    sign_in_legacy @legacy_user

    get logo_certifier_settings_path

    assert_response :not_found
  end
end
