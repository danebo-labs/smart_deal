import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { config: Object }

  connect() {
    if (!this.configValue?.labels?.length) return
    if (!window.Chart) {
      console.error("cost-chart: Chart.js not loaded")
      return
    }

    this.chart = new window.Chart(this.element, {
      type: "line",
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
              label: (ctx) => `${ctx.dataset.label}: $${ctx.parsed.y.toFixed(4)}`
            }
          }
        },
        scales: {
          x: {
            title: { display: true, text: "Día del mes" }
          },
          y: {
            beginAtZero: true,
            title: { display: true, text: "USD" },
            ticks: {
              callback: (value) => `$${Number(value).toFixed(2)}`
            }
          }
        }
      }
    })
  }

  disconnect() {
    this.chart?.destroy()
  }
}
