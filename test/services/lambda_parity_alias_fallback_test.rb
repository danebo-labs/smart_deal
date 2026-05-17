# frozen_string_literal: true

require "test_helper"

class LambdaParityAliasFallbackTest < ActiveSupport::TestCase
  test "strips file extension before generating aliases" do
    result = LambdaParityAliasFallback.generate("manual.pdf")
    assert_not_includes result, "manual.pdf"
    assert_includes result, "manual"
  end

  test "lowercases all tokens" do
    result = LambdaParityAliasFallback.generate("Orona-Basic-Arc.pdf")
    assert_includes result, "orona"
    assert_includes result, "basic"
    assert_includes result, "orona basic"
  end

  test "filters out tokens shorter than 4 chars" do
    result = LambdaParityAliasFallback.generate("arc-I-v1.pdf")
    assert_not_includes result, "arc"  # 3 chars
    assert_not_includes result, "i"    # 1 char
    assert_not_includes result, "v1"   # 2 chars
  end

  test "generates bigrams from adjacent 4+ char tokens" do
    result = LambdaParityAliasFallback.generate("orona-basic-arca.pdf")
    assert_includes result, "orona basic"
    assert_includes result, "basic arca"
  end

  test "does NOT generate bigram when either word is < 4 chars" do
    result = LambdaParityAliasFallback.generate("orona-to-basic.pdf")
    # "to" is 2 chars → bigrams "orona to" and "to basic" are excluded
    assert_not_includes result, "orona to"
    assert_not_includes result, "to basic"
    assert_includes result, "orona"
    assert_includes result, "basic"
  end

  test "sorts aliases alphabetically" do
    result = LambdaParityAliasFallback.generate("pump-hydraulic-manual.pdf")
    assert_equal result, result.sort
  end

  test "deduplicates results" do
    result = LambdaParityAliasFallback.generate("pump-pump.pdf")
    assert_equal result.uniq, result
  end

  test "returns empty array for blank filename" do
    assert_equal [], LambdaParityAliasFallback.generate("")
    assert_equal [], LambdaParityAliasFallback.generate(nil)
  end

  test "real filename from the plan produces expected aliases" do
    # 952408286-Orona-basic-arc-arca-I.pdf
    # Words: ["952408286", "orona", "basic", "arc"(3), "arca", "i"(1)]
    # Tokens >= 4: 952408286, orona, basic, arca
    # Bigrams (both >= 4): "952408286 orona", "orona basic"
    # Note: "basic arc" excluded ("arc"=3 chars), "arc arca" excluded ("arc"=3 chars)
    result = LambdaParityAliasFallback.generate("952408286-Orona-basic-arc-arca-I.pdf")
    assert_includes result, "952408286"
    assert_includes result, "orona"
    assert_includes result, "basic"
    assert_includes result, "arca"
    assert_includes result, "orona basic"
    assert_includes result, "952408286 orona"
    # "arc" and "I" are short → excluded as single tokens and from bigrams
    assert_not_includes result, "arc"
    assert_not_includes result, "i"
    assert_not_includes result, "basic arca"  # "arc" between them breaks adjacency
  end
end
