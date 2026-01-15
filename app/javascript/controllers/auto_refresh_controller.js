import { Controller } from "@hotwired/stimulus"

// Auto-refresh controller for schedule page
// Refreshes at game start times and estimated end times
export default class extends Controller {
  static values = {
    gameTimes: Array // Array of game timestamps in milliseconds
  }

  connect() {
    this.scheduleNextRefresh()
  }

  disconnect() {
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer)
    }
  }

  scheduleNextRefresh() {
    const now = Date.now()
    const gameDuration = 2.5 * 60 * 60 * 1000 // 2.5 hours in ms

    // Collect all relevant times: game starts and estimated ends
    const refreshTimes = []
    this.gameTimesValue.forEach(gameTime => {
      refreshTimes.push(gameTime) // Game start
      refreshTimes.push(gameTime + gameDuration) // Game end estimate
    })

    // Find next refresh time (must be in the future)
    const futureTimes = refreshTimes.filter(t => t > now)

    if (futureTimes.length === 0) {
      // No upcoming changes, no need to refresh
      return
    }

    const nextRefresh = Math.min(...futureTimes)
    const delay = nextRefresh - now + 1000 // +1 sec buffer

    // Max delay: 30 minutes (in case of very long waits)
    const maxDelay = 30 * 60 * 1000
    const actualDelay = Math.min(delay, maxDelay)

    this.refreshTimer = setTimeout(() => {
      Turbo.visit(window.location.href, { action: "replace" })
    }, actualDelay)
  }
}
