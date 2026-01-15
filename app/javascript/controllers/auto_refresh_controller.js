import { Controller } from "@hotwired/stimulus"

// Auto-refresh controller for schedule page
// Refreshes the page every N seconds to update game statuses
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 60 } // seconds
  }

  connect() {
    this.startRefresh()
  }

  disconnect() {
    this.stopRefresh()
  }

  startRefresh() {
    this.refreshTimer = setInterval(() => {
      // Use Turbo to refresh without full page reload
      Turbo.visit(window.location.href, { action: "replace" })
    }, this.intervalValue * 1000)
  }

  stopRefresh() {
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer)
    }
  }
}
