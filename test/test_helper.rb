# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'

begin
  require 'vips'
rescue LoadError
  # vips not installed, load mock
  require_relative 'support/mock_vips'
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    # Disable parallelization completely in CI to prevent connection pool exhaustion
    # Keep full parallelization for local development
    if ENV['CI']
      parallelize(workers: 1) # Single worker in CI to prevent connection issues
    else
      parallelize(workers: :number_of_processors)
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
