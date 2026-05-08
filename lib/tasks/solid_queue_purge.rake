# frozen_string_literal: true

namespace :solid_queue do
  desc <<~DESC.squish
    Delete all Solid Queue jobs and worker bookkeeping (queue DB).
    Removes tmp/bulk_uploads/*.zip. Use CLEAN_BULK_UPLOADS=1 to destroy BulkUpload rows.
    Stop bin/jobs first. Production: set FORCE_PURGE_QUEUE=1.
  DESC
  task purge_all: :environment do
    unless Rails.env.local? || ENV["FORCE_PURGE_QUEUE"].present?
      puts "Refusing: use development/test, or FORCE_PURGE_QUEUE=1"
      exit 1
    end

    n_jobs = SolidQueue::Job.count
    puts "Purging Solid Queue (#{n_jobs} job row(s))…"

    SolidQueue::Job.delete_all
    SolidQueue::Process.delete_all
    SolidQueue::Semaphore.delete_all
    SolidQueue::Pause.delete_all

    dir = Rails.root.join("tmp/bulk_uploads")
    if dir.directory?
      n_zip = Dir.glob(dir.join("*.zip")).each { |p| FileUtils.rm_f(p) }.size
      puts "Removed #{n_zip} file(s) under tmp/bulk_uploads/"
    end

    if ENV["CLEAN_BULK_UPLOADS"].present?
      destroyed = BulkUpload.destroy_all.size
      puts "Destroyed #{destroyed} BulkUpload record(s)."
    end

    puts "Done. SolidQueue::Job.count=#{SolidQueue::Job.count}"
  end
end
