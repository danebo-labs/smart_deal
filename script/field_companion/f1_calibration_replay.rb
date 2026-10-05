# frozen_string_literal: true

# Offline rescore of the stored F1 calibration outputs.
# No Bedrock. Reads gitignored tmp/f1cal/runs and prints v1 against v2.
# Usage: bin/rails runner script/field_companion/f1_calibration_replay.rb

require_relative "f1_calibration_score"

runs_dir = ENV["F1CAL_RUNS"].presence || Rails.root.join("tmp/f1cal/runs").to_s
paths = Dir[File.join(runs_dir, "f1cal.r*.json")].sort
abort "no stored runs in #{runs_dir}" if paths.empty?

Score = FieldCompanion::F1CalibrationScore
report = { "score_revision" => Score::SCORE_REVISION, "runs" => [], "unexpected" => [] }

paths.each do |path|
  data = JSON.parse(File.read(path))
  rows = data.fetch("rows")
  changes = []
  unknown = rows.select { |row| row["identity"] == "unknown" }
  v1 = Hash.new(0)
  v2 = Hash.new(0)
  groups = {
    "unknown" => unknown,
    "s1" => unknown.select { |row| Score::S1.include?(row["id"]) },
    "s2" => unknown.select { |row| Score::S2.include?(row["id"]) },
    "s3" => unknown.reject { |row| Score::S1.include?(row["id"]) || Score::S2.include?(row["id"]) }
  }
  unknown.each do |row|
    text = row["published"].to_s
    scored = Score.score_publish(row["id"], row["question"], text, row["route_outcome"])
    stored_useful = row["useful"] == true
    if stored_useful != scored[:useful_v1]
      report["unexpected"] << {
        "file" => File.basename(path), "id" => row["id"], "lane" => row["lane"],
        "reason" => "stored useful does not match recomputed v1",
        "stored" => stored_useful, "v1" => scored[:useful_v1]
      }
    end
    if scored[:useful] && !scored[:useful_v1]
      report["unexpected"] << {
        "file" => File.basename(path), "id" => row["id"], "lane" => row["lane"],
        "reason" => "v2 useful increased over v1"
      }
    end
    v1[:useful] += 1 if scored[:useful_v1]
    v2[:useful] += 1 if scored[:useful]
    v1[:unsafe] += 1 if row["unsafe_publication"] == true
    v2[:unsafe] += 1 if scored[:unsafe_publication]
    v1[:guard] += 1 if row["guard_held"] == true
    v2[:guard] += 1 if row["guard_held"] == true
    v2[:formulaic] += 1 if scored[:formulaic]
    v2[:qualified_reference] += 1 if scored[:qualified_reference]
    v2[:step_list] += 1 if scored[:qualified_foreign_step_list]
    next if stored_useful == scored[:useful] && (row["unsafe_publication"] == true) == scored[:unsafe_publication]

    reasons = []
    reasons << "observation verb and topic are not in the same line" if stored_useful && !scored[:useful]
    reasons << "unexpected useful increase" if scored[:useful] && !scored[:useful_v1]
    reasons << "foreign fixture fact outside a local qualified reference" if scored[:unsafe_publication] && row["unsafe_publication"] != true
    reasons << "unsafe flag cleared" if row["unsafe_publication"] == true && !scored[:unsafe_publication]
    reason = reasons.join("; ").presence || "classification changed"
    changes << {
      "id" => row["id"], "lane" => row["lane"], "reason" => reason,
      "useful_v1" => stored_useful, "useful_v2" => scored[:useful],
      "unsafe_v1" => row["unsafe_publication"] == true, "unsafe_v2" => scored[:unsafe_publication]
    }
  end
  summary = data["summary"] || {}
  report["runs"] << {
    "file" => File.basename(path),
    "prompt_version" => summary["prompt_version"],
    "executions" => rows.size,
    "unknown" => unknown.size,
    "v1" => { "useful" => v1[:useful], "guard" => v1[:guard], "unsafe" => v1[:unsafe] },
    "v2" => {
      "useful" => v2[:useful], "guard" => v2[:guard], "unsafe" => v2[:unsafe],
      "qualified_reference" => v2[:qualified_reference],
      "step_list" => v2[:step_list], "formulaic" => v2[:formulaic]
    },
    "groups_v2_useful" => groups.transform_values { |selected|
      selected.count { |row|
        scored = Score.score_publish(row["id"], row["question"], row["published"].to_s, row["route_outcome"])
        scored[:useful]
      }
    },
    "changes" => changes
  }
end

out = ENV["F1CAL_REPLAY_OUT"].presence || Rails.root.join("tmp/f1cal/v2_replay.json").to_s
FileUtils.mkdir_p(File.dirname(out))
File.write(out, JSON.pretty_generate(report))
puts JSON.pretty_generate(report["runs"].map { |run|
  run.except("changes").merge("change_count" => run["changes"].size)
})
puts "changes:"
report["runs"].each do |run|
  run["changes"].each do |change|
    puts "#{run['file']} #{change['id']} #{change['lane']} #{change['reason']} useful #{change['useful_v1']}->#{change['useful_v2']} unsafe #{change['unsafe_v1']}->#{change['unsafe_v2']}"
  end
end
puts "unexpected=#{report['unexpected'].size} wrote #{out}"
exit(report["unexpected"].empty? ? 0 : 2)
