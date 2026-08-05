# frozen_string_literal: true

require "cgi"
require "csv"
require "fileutils"

abort(
  "Run with: bin/rails runner script/pilot_metrics_package.rb REPORT_JSON OUTPUT_DIR [OUTCOMES_CSV]"
) unless defined?(Rails)

class PilotMetricsPackage
  MANUAL_OUTCOME_HEADERS = %w[correlation_id correct_answer resolved helpfulness].freeze
  CSV_HEADERS = %w[
    correlation_id occurred_at outcome route question answer documents pages citations
    chunks input_tokens output_tokens attributed_cost_usd correct_answer resolved
    technician_helpfulness
  ].freeze

  def initialize(report_path:, output_dir:, outcomes_path: nil)
    @report_path = report_path
    @output_dir = output_dir
    @outcomes_path = outcomes_path
  end

  def call
    FileUtils.mkdir_p(output_dir)
    report = JSON.parse(File.read(report_path))
    merge_manual_outcomes!(report) if outcomes_path
    File.write(report_path, JSON.generate(report)) if outcomes_path

    value = PilotValueReport.new(report).as_json
    File.write(File.join(output_dir, "report.txt"), "#{PilotMetricsHumanFormatter.new(report.deep_symbolize_keys)}\n")
    File.write(File.join(output_dir, "valor.json"), JSON.pretty_generate(value))
    File.write(File.join(output_dir, "dossier.html"), dossier_html(report, value))
    File.write(File.join(output_dir, "interactions.csv"), interactions_csv(report))
  end

  private

  attr_reader :report_path, :output_dir, :outcomes_path

  def merge_manual_outcomes!(report)
    outcomes = CSV.read(outcomes_path, headers: true)
    missing_headers = MANUAL_OUTCOME_HEADERS - outcomes.headers
    if missing_headers.any?
      abort("manual outcomes CSV missing headers: #{missing_headers.join(',')}")
    end

    by_correlation = outcomes.index_by { |outcome| outcome["correlation_id"] }
    interactions(report).each do |interaction|
      outcome = by_correlation[interaction["correlation_id"]]
      next unless outcome

      interaction["correct_answer"] = outcome["correct_answer"]
      interaction["resolved"] = outcome["resolved"]
      interaction["technician_helpfulness"] = outcome["helpfulness"]
    end
  end

  def dossier_html(report, value)
    <<~HTML
      <!doctype html>
      <html lang="es">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Dossier de valor Danebo — #{escape(report["date"] || "n/a")}</title>
        <style>
          :root { color-scheme: light; --ink:#172033; --muted:#637083; --line:#dce2ea; --brand:#1859d1; --soft:#f4f7fb; --good:#087f5b; }
          * { box-sizing:border-box; }
          body { margin:0; background:#eef2f7; color:var(--ink); font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
          main { width:min(1120px,calc(100% - 32px)); margin:32px auto 64px; }
          header,.panel,.interaction { background:white; border:1px solid var(--line); border-radius:14px; box-shadow:0 6px 20px rgba(23,32,51,.05); }
          header { padding:28px; }
          h1,h2,h3 { margin:0 0 10px; line-height:1.2; }
          h1 { font-size:28px; } h2 { margin-top:32px; font-size:21px; } h3 { font-size:17px; }
          .muted,.meta { color:var(--muted); }
          .metrics { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:12px; margin-top:22px; }
          .metric { padding:16px; background:var(--soft); border-radius:10px; }
          .metric strong { display:block; margin-top:4px; font-size:22px; color:var(--brand); }
          .panel { padding:22px; margin-top:18px; }
          .interaction { padding:22px; margin-top:14px; }
          .interaction-grid { display:grid; grid-template-columns:1fr 1fr; gap:18px; margin-top:16px; }
          .content { white-space:pre-wrap; overflow-wrap:anywhere; }
          .sources { padding-left:20px; }
          .trace { display:flex; flex-wrap:wrap; gap:12px; margin-top:14px; padding-top:12px; border-top:1px solid var(--line); color:var(--muted); font-size:13px; }
          details { margin-top:10px; padding:10px 12px; border:1px solid var(--line); border-radius:8px; background:var(--soft); }
          summary { cursor:pointer; font-weight:600; }
          pre { white-space:pre-wrap; overflow-wrap:anywhere; font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace; }
          .status { color:var(--good); font-weight:600; text-transform:uppercase; font-size:12px; letter-spacing:.04em; }
          @media (max-width:720px) { .interaction-grid { grid-template-columns:1fr; } main { width:min(100% - 20px,1120px); margin-top:10px; } }
        </style>
      </head>
      <body>
        <main>
          <header>
            <div class="status">Dossier auditable</div>
            <h1>Valor del piloto Danebo</h1>
            <div class="muted">#{escape(report["date"] || "n/a")} · #{escape(report["timezone"] || "n/a")} · generado #{escape(report["generated_at"] || "n/a")}</div>
            #{value_metrics_html(value)}
          </header>
          <section class="panel">
            <h2>Brechas y revisión humana</h2>
            <p>Abstenciones: <strong>#{escape(value.dig(:knowledge_gaps, :by_signal, :abstained))}</strong> · DATA_NOT_AVAILABLE: <strong>#{escape(value.dig(:knowledge_gaps, :by_signal, :data_not_available))}</strong></p>
            <p>Corrección verificada: <strong>#{escape(metric(value.dig(:precision_and_safety, :verified_correct_rate), percent: true))}</strong> · Estado: #{escape(value.dig(:precision_and_safety, :verification_status))}</p>
          </section>
          <h2>Interacciones</h2>
          #{interactions(report).map { |interaction| interaction_html(interaction) }.join("\n")}
        </main>
      </body>
      </html>
    HTML
  end

  def value_metrics_html(value)
    metrics = [
      [ "Respuestas auditables", metric(value.dig(:auditability, :audited_answer_rate), percent: true) ],
      [ "Tasa de abstención", metric(value.dig(:precision_and_safety, :abstention_rate), percent: true) ],
      [ "Costo por respuesta", metric(value.dig(:value_capture, :cost_per_answered_interaction_usd), money: true) ],
      [ "Tiempo de respuesta p50", metric(value.dig(:value_capture, :answer_time_p50_s), seconds: true) ],
      [ "Tiempo de respuesta p95", metric(value.dig(:value_capture, :answer_time_p95_s), seconds: true) ],
      [ "Usuarios activos", metric(value.dig(:adoption, :active_users)) ]
    ]
    %(<div class="metrics">#{metrics.map { |label, raw| %(<div class="metric">#{escape(label)}<strong>#{escape(raw)}</strong></div>) }.join}</div>)
  end

  def interaction_html(interaction)
    audit = interaction["audit"] || {}
    question = audit["question"] || interaction["question"] || "n/a"
    answer = audit["answer"] || interaction["answer_snippet"] || "n/a"
    citations = Array(audit["citations"])
    sources = if citations.any?
      citations.map do |citation|
        title = citation["title"].presence || citation["filename"].presence || "Documento"
        page = if citation["page"].present? && !title.match?(/(?:—|·)\s+p\.\s*\d+/)
          " · p. #{citation['page']}"
        else
          ""
        end
        "#{title}#{page}"
      end
    else
      Array(interaction["citation_titles"]).presence || Array(interaction["documents"])
    end
    chunks = Array(audit["chunks"])

    <<~HTML
      <article class="interaction">
        <div class="status">#{escape(interaction["outcome"] || "sin resultado")}</div>
        <h3>#{escape(interaction["correlation_id"] || "sin correlation_id")}</h3>
        <div class="interaction-grid">
          <section><strong>Pregunta</strong><div class="content">#{escape(question)}</div></section>
          <section><strong>Respuesta</strong><div class="content">#{escape(answer)}</div></section>
        </div>
        <section>
          <strong>Fuentes</strong>
          #{sources.any? ? %(<ul class="sources">#{sources.map { |source| "<li>#{escape(source)}</li>" }.join}</ul>) : %(<p class="muted">Sin fuente registrada.</p>)}
        </section>
        #{chunks_html(chunks)}
        <div class="trace">
          <span>correlation_id: #{escape(interaction["correlation_id"] || "n/a")}</span>
          <span>tokens: #{escape(interaction["input_tokens"] || 0)} in / #{escape(interaction["output_tokens"] || 0)} out</span>
          <span>costo: #{escape(metric(interaction["attributed_cost_usd"], money: true))}</span>
        </div>
      </article>
    HTML
  end

  def chunks_html(chunks)
    return "" if chunks.empty?

    chunks.each_with_index.map do |chunk, index|
      label = [ chunk["document"], ("p. #{chunk['page']}" if chunk["page"]), chunk["section_identity"] ]
        .compact_blank.join(" · ")
      <<~HTML
        <details>
          <summary>Chunk #{index + 1} · #{escape(label.presence || "sin identidad")}</summary>
          <div class="meta">SHA256: #{escape(chunk["chunk_sha256"] || "n/a")} · truncado: #{escape(chunk["truncated"] == true ? "sí" : "no")}</div>
          <pre>#{escape(chunk["text"] || "")}</pre>
        </details>
      HTML
    end.join
  end

  def interactions_csv(report)
    CSV.generate(headers: CSV_HEADERS, write_headers: true) do |csv|
      interactions(report).each do |interaction|
        audit = interaction["audit"] || {}
        citations = Array(audit["citations"])
        chunks = Array(audit["chunks"])
        documents = (
          Array(interaction["documents"]) + citations.filter_map { |citation| citation["title"] || citation["filename"] }
        ).uniq
        pages = (Array(interaction["pages"]) + citations.filter_map { |citation| citation["page"] }).uniq
        csv << [
          interaction["correlation_id"], interaction["occurred_at"], interaction["outcome"], interaction["route"],
          audit["question"] || interaction["question"], audit["answer"] || interaction["answer_snippet"],
          documents.join(" | "), pages.join(" | "), interaction["citations_count"], chunks.size,
          interaction["input_tokens"], interaction["output_tokens"], interaction["attributed_cost_usd"],
          interaction["correct_answer"], interaction["resolved"], interaction["technician_helpfulness"]
        ]
      end
    end
  end

  def interactions(report)
    Array(report.dig("interactions", "by_correlation"))
  end

  def metric(value, percent: false, money: false, seconds: false)
    return "n/a" if value.nil? || value == "n/a"
    return format("%.1f%%", value.to_f * 100) if percent
    return format("$%.6f", value.to_f) if money
    return format("%.3fs", value.to_f) if seconds

    value.to_s
  end

  def escape(value)
    CGI.escapeHTML(value.to_s)
  end
end

report_path, output_dir, outcomes_path = ARGV.values_at(0, 1, 2)
abort("REPORT_JSON and OUTPUT_DIR are required") unless report_path && output_dir

PilotMetricsPackage.new(
  report_path: report_path,
  output_dir: output_dir,
  outcomes_path: outcomes_path
).call
