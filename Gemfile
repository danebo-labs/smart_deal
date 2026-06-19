# frozen_string_literal: true
ruby '~> 3.4.0'

source 'https://rubygems.org'

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem 'rails', '~> 8.1.1'
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem 'propshaft'
# Use sqlite3 as the database for Active Record
gem 'sqlite3', '>= 2.1'
# PostgreSQL adapter for client business databases (Text-to-SQL)
gem 'pg', '~> 1.5.0'
# Use the Puma web server [https://github.com/puma/puma]
gem 'puma', '>= 5.0'
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem 'importmap-rails'
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem 'turbo-rails'
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem 'stimulus-rails'
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem 'jbuilder'

# Authentication
gem 'devise', '>= 5.0.4'

# Patched Trix (Rails actiontext; GHSA-53p3-c7vp-4mcc / prior GHSA-qmpg-8xg6-ph5q)
gem 'action_text-trix', '>= 2.1.18'

# Bundler-audit: GHSA-h27x-rffw-24p4 (addressable < 2.9.0 ReDoS in templates)
gem 'addressable', '>= 2.9.0'

# Bundler-audit: GHSA-c4rq-3m3g-8wgx, GHSA-v2fc-qm4h-8hqv (nokogiri < 1.19.3)
gem 'nokogiri', '>= 1.19.3'

# Bundler-audit: CVE-2026-33637 (faraday < 2.14.2, via twilio-ruby / ruby-openai)
gem 'faraday', '>= 2.14.2'

# Bundler-audit: CVE-2026-45363 (jwt < 3.2.0, via twilio-ruby)
gem 'jwt', '>= 3.2.0'

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem 'tzinfo-data', platforms: %i[windows jruby]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem 'solid_cable'
gem 'solid_cache'
gem 'solid_queue'
gem 'mission_control-jobs'

# Reduces boot times through caching; required in config/boot.rb
gem 'bootsnap', require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem 'thruster', require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem 'image_processing', '~> 1.2'
gem 'ruby-vips'

# PDF processing
gem 'pdf-reader'
gem 'hexapdf'

# OpenAI integration
gem 'ruby-openai'

# AWS Bedrock integration
gem 'aws-sdk-bedrock'
gem 'aws-sdk-bedrockagent'
gem 'aws-sdk-bedrockagentruntime'
gem 'aws-sdk-bedrockruntime'

# AWS services for metrics
gem 'aws-sdk-cloudwatch'
gem 'aws-sdk-rds'
gem 'aws-sdk-s3', '>= 1.208.0'

gem 'twilio-ruby'

gem "appsignal"
gem 'httparty'

# Anthropic Claude API (Batch API for bulk ingestion)
gem 'anthropic'

# ZIP file extraction for bulk uploads
gem 'rubyzip'



group :development, :test do
  # Environment variables management
  gem 'dotenv-rails'


  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem 'debug', platforms: %i[mri windows], require: 'debug/prelude'

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem 'bundler-audit', require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem 'brakeman', '~> 8.0.5', require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem 'rubocop-rails-omakase', require: false

  gem 'rubocop-capybara', require: false

  # OpenStruct for Ruby 4.0 compatibility
  gem 'ostruct'
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem 'web-console'
  gem "kamal", "~> 2.0", require: false
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem 'capybara'
  gem 'selenium-webdriver'
end

gem "tailwindcss-rails", "~> 4.4"
