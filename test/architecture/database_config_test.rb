# frozen_string_literal: true

require "test_helper"

class DatabaseConfigTest < ActiveSupport::TestCase
  test "test databases use the OS user unless DB_USERNAME is set" do
    expected = ENV["DB_USERNAME"].presence || ENV["USER"].presence || "app_user"

    %w[primary cache queue cable].each do |name|
      config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: name)
      assert_equal expected, config.configuration_hash[:username],
                   "test #{name} must not default to app_user (cannot DISABLE TRIGGER ALL for fixtures)"
    end
  end
end
