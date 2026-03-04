require 'minitest/autorun'
require 'minitest/mock'

class MyTest < Minitest::Test
  def run
    puts "Wrapper before"
    String.stub(:new, "stubbed") do
      super
    end
    puts "Wrapper after"
  end

  def test_something
    assert_equal "stubbed", String.new
  end
end
