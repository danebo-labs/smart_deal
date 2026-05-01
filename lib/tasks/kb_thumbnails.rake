# frozen_string_literal: true

# Thumbnail backfill for KbDocuments uploaded before thumbnail support was added.
namespace :kb do
  namespace :thumbnails do
    desc "Backfill thumbnails for image KbDocuments indexed before thumbnail support was added"
    task backfill: :environment do
      require 'aws-sdk-s3'

      IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif].freeze

      docs = KbDocument
        .left_outer_joins(:thumbnail)
        .where(kb_document_thumbnails: { id: nil })
        .select { |d| IMAGE_EXTENSIONS.include?(File.extname(d.s3_key.to_s).downcase) }

      puts "Found #{docs.size} image KbDocument(s) without thumbnails."
      next if docs.empty?

      s3_service = S3DocumentsService.new
      bucket     = s3_service.bucket_name

      s3_client = Aws::S3::Client.new(
        region:      ENV.fetch("AWS_REGION", "us-east-1"),
        credentials: Aws::Credentials.new(
          ENV.fetch("AWS_ACCESS_KEY_ID"),
          ENV.fetch("AWS_SECRET_ACCESS_KEY")
        )
      )

      ok = 0; fail_count = 0

      docs.each do |doc|
        key = KbDocument.object_key_for_match(doc.s3_key)
        print "  #{key} … "

        resp = s3_client.get_object(bucket: bucket, key: key)
        blob = resp.body.read

        svc     = ImageCompressionService.new(Base64.strict_encode64(blob), "image/jpeg")
        payload = svc.send(:build_thumbnail, svc.send(:decoded_blob))

        doc.create_thumbnail!(
          data:         payload[:thumbnail_binary],
          content_type: payload[:thumbnail_content_type],
          width:        payload[:thumbnail_width],
          height:       payload[:thumbnail_height],
          byte_size:    payload[:thumbnail_binary].bytesize
        )
        puts "ok (#{payload[:thumbnail_binary].bytesize} bytes)"
        ok += 1
      rescue StandardError => e
        puts "FAILED — #{e.message}"
        fail_count += 1
      end

      puts "\nDone: #{ok} ok, #{fail_count} failed."
    end
  end
end
