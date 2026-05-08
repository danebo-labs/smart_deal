# frozen_string_literal: true

require "test_helper"
require "benchmark"

class BulkUploadsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    sign_in @user
  end

  # ---------------------------------------------------------------------------
  # #new
  # ---------------------------------------------------------------------------

  test "GET new renders the upload form" do
    get new_bulk_upload_path
    assert_response :success
    assert_select "form[action='#{bulk_uploads_path}']"
    assert_select "input[type='file'][accept='.zip']"
  end

  test "GET new redirects unauthenticated user" do
    sign_out @user
    get new_bulk_upload_path
    assert_response :redirect
  end

  # ---------------------------------------------------------------------------
  # #create
  # ---------------------------------------------------------------------------

  test "POST create enqueues ProcessBulkUploadJob and redirects to show" do
    zip_data = minimal_zip_binary

    assert_enqueued_with(job: ProcessBulkUploadJob) do
      measured = Benchmark.realtime do
        post bulk_uploads_path, params: { zip_file: zip_upload(zip_data) }
      end
      # ACK < 100 ms (generous: 500 ms in test env to avoid flakiness from CI overhead)
      assert measured < 0.5, "create took #{(measured * 1000).round}ms — expected <500ms in test"
    end

    bulk_upload = BulkUpload.order(:created_at).last
    assert_not_nil bulk_upload
    assert_equal "test_batch.zip", bulk_upload.original_filename
    assert_equal "pending", bulk_upload.status

    assert_redirected_to bulk_upload_path(bulk_upload)
  end

  test "POST create is idempotent: duplicate ZIP redirects to existing BulkUpload" do
    zip_data = minimal_zip_binary

    post bulk_uploads_path, params: { zip_file: zip_upload(zip_data) }
    first_upload = BulkUpload.order(:created_at).last

    assert_no_enqueued_jobs only: ProcessBulkUploadJob do
      post bulk_uploads_path, params: { zip_file: zip_upload(zip_data) }
    end

    assert_redirected_to bulk_upload_path(first_upload)
    assert_equal 1, BulkUpload.where(sha256: first_upload.sha256).count
  end

  test "POST create with no file redirects back to new with alert" do
    post bulk_uploads_path, params: {}
    assert_redirected_to new_bulk_upload_path
    follow_redirect!
    assert_select "div", text: /Selecciona un archivo ZIP/
  end

  test "POST create redirects unauthenticated user" do
    sign_out @user
    post bulk_uploads_path, params: { zip_file: zip_upload(minimal_zip_binary) }
    assert_response :redirect
    assert_no_match bulk_uploads_path, response.location
  end

  # ---------------------------------------------------------------------------
  # #show
  # ---------------------------------------------------------------------------

  test "GET show renders the page with Turbo Stream subscription" do
    upload = BulkUpload.create!(
      sha256:            SecureRandom.hex(16),
      original_filename: "demo.zip",
      status:            "processing",
      asset_count:       1,
      user:              @user
    )

    get bulk_upload_path(upload)
    assert_response :success
    assert_select "turbo-cable-stream-source[channel='Turbo::StreamsChannel']"
    assert_match upload.original_filename, response.body
  end

  test "GET show returns 404 for unknown BulkUpload" do
    get bulk_upload_path(id: 999_999)
    assert_response :not_found
  end

  private

  # Minimal valid ZIP (contains no entries — still parseable by Zip::File).
  def minimal_zip_binary
    require "zip"
    buf = StringIO.new("".b)
    Zip::OutputStream.write_buffer(buf) { |_z| }
    buf.string
  end

  def zip_upload(binary)
    Rack::Test::UploadedFile.new(
      StringIO.new(binary),
      "application/zip",
      true,
      original_filename: "test_batch.zip"
    )
  end
end
