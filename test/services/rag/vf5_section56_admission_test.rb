# frozen_string_literal: true

require "test_helper"

ENV["VF5_SECTION56_LED_REQUIRE"] = "1"
load Rails.root.join("script/field_companion/vf5_section56_led.rb")

class Rag::Vf5Section56AdmissionTest < ActiveSupport::TestCase
  test "the first call is admitted only when the full reserve fits both limits" do
    decision = vf5_led_admit(ledger(61, "0.841346"), opening, "0.047955")

    assert decision["admitted"]
    assert_equal "0.000000", decision["additional_usd"]
    assert_equal "0.047955", decision["job_total_usd"]
    assert_equal "0.889301", decision["global_total_usd"]
  end

  test "a later call uses the full reserve and not the previous settled cost" do
    full = vf5_led_admit(ledger(63, "0.961346"), opening, "0.050000")
    previous_call = vf5_led_admit(ledger(63, "0.961346"), opening, "0.012000")

    assert_equal false, full["admitted"]
    assert_equal [ "job_usd" ], full["reasons"]
    assert_equal "0.120000", full["additional_usd"]
    assert previous_call["admitted"]
  end

  test "an open hold and an unknown cost count toward the next reserve" do
    held = vf5_led_admit(ledger(62, "0.841346", held: "0.120000"), opening, "0.050000")
    unknown = vf5_led_admit(ledger(63, "0.841346", unknown: "0.120000"), opening, "0.050000")

    assert_equal false, held["admitted"]
    assert_equal false, unknown["admitted"]
    assert_includes held["reasons"], "job_usd"
    assert_includes unknown["reasons"], "job_usd"
  end

  test "three full reserves of the observed size still fit the job limit" do
    decision = vf5_led_admit(ledger(63, "0.937256"), opening, "0.047955")

    assert decision["admitted"]
    assert_equal "0.095910", decision["additional_usd"]
    assert_equal "0.143865", decision["job_total_usd"]
  end

  test "the next reserve must also fit the cumulative dollar cap" do
    start = opening(attempts: 70, committed: "3.960000")
    fits = vf5_led_admit(ledger(70, "3.960000"), start, "0.040000")
    over = vf5_led_admit(ledger(70, "3.960000"), start, "0.040001")

    assert fits["admitted"]
    assert_equal false, over["admitted"]
    assert_equal [ "global_usd" ], over["reasons"]
  end

  test "attempt count keeps the validation reserve and the job cap" do
    assert vf5_led_admit(ledger(80, "0.841346"), opening(attempts: 80), "0.040000")["admitted"]
    blocked = vf5_led_admit(ledger(81, "0.841346"), opening(attempts: 81), "0.040000")
    spent = vf5_led_admit(ledger(64, "0.841346"), opening, "0.040000")

    assert_equal false, blocked["admitted"]
    assert_equal [ "attempts" ], blocked["reasons"]
    assert_equal false, spent["admitted"]
    assert_equal [ "attempts" ], spent["reasons"]
  end

  test "the applicability line is only the fourth result and removing it restores the prompt" do
    label = "THIS JOB'S EQUIPMENT: VF5"
    base = (1..3).map { |number|
      "<search_result>\n<content>\n#{label}\nbody #{number}\n</content>\n<source>\n#{number}\n</source>\n</search_result>"
    }
    base << "<search_result>\n<content>\nchunk-body\n</content>\n<source>\n4\n</source>\n</search_result>"
    base = "#{base.join("\n")}\n\nand which remain open\n"
    marked = vf5_led_prompt(base, label)

    assert_equal base, vf5_led_without_mark(marked, label)
    contents = marked.to_enum(:scan, SectionPageContinuity::RESULT_PATTERN).map { Regexp.last_match[1] }
    assert_equal [ "1", "2", "3", "4" ].map { |number| "#{label}\nbody #{number}" }.first(3), contents.first(3)
    assert_equal "#{label}\nchunk-body", contents[3]
    assert_equal base.scan(label).size + 1, marked.scan(label).size
  end

  private

  def opening(attempts: 61, committed: "0.841346")
    { "attempts" => attempts, "committed_usd" => committed, "unknown_usd" => "0.000000", "held_usd" => "0.000000" }
  end

  def ledger(attempts, committed, unknown: "0.000000", held: "0.000000")
    { "attempts" => attempts, "committed_usd" => committed, "unknown_usd" => unknown, "held_usd" => held }
  end
end
