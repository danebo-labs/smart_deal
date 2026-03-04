require_relative 'test_helper'

class MyRailsTest < ActiveSupport::TestCase
  around do |test|
    puts "Around before"
    String.stub(:new, "stubbed") do
      test.call
    end
    puts "Around after"
  end

  test "something" do
    assert_equal "stubbed", String.new
  end
end
