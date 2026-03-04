require 'minitest/autorun'

module Wrapper
  def run
    puts "Before"
    String.stub(:new, "stubbed") do
      super
    end
    puts "After"
  end
end

class MyTest < Minitest::Test
  prepend Wrapper

  def test_something
    assert_equal "stubbed", String.new
  end
end
