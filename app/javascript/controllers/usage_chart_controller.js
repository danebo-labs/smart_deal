import { Controller } from "@hotwired/stimulus"

// Stacked bar chart of query volume (not parameterized from cost_chart_controller:
// that one hardcodes "$"/"USD" in its tooltip and axis — this one must never
// render either).
export default class extends Controller {
  static values = { config: Object }

  connect() {
    if (!this.configValue?.labels?.length) return
    if (!window.Chart) {
      console.error("usage-chart: Chart.js not loaded")
      return
    }

    this.chart = new window.Chart(this.element, {
      type: "bar",
      data: {
        labels: this.configValue.labels,
        datasets: this.configValue.datasets || []
      },
      options: {
        responsive: true,
        maintainAspectRatio: true,
        interaction: { mode: "index", intersect: false },
        plugins: {
          legend: { position: "bottom" },
          tooltip: {
            callbacks: {
              label: (ctx) => `${ctx.dataset.label}: ${ctx.parsed.y}`
            }
          }
        },
        scales: {
          x: {
            stacked: true,
            title: { display: true, text: "Día" }
          },
          y: {
            stacked: true,
            beginAtZero: true,
            title: { display: true, text: "Consultas" },
            ticks: { precision: 0 }
          }
        }
      }
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
