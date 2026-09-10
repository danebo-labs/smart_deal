import { Controller } from "@hotwired/stimulus"

// Fase 1B: "Imprimir / guardar como PDF (provisional)" on the report review
// page. window.print() is the only thing this needs — a full framework
// action for one browser call would be unnecessary frontend state.
export default class extends Controller {
  print() {
    window.print()
  }
}
