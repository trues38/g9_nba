import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { mode: String }
  static targets = ["body", "header", "main", "tabBar", "metaTheme"]

  connect() {
    this.applyTheme(this.modeValue || 'dark')
  }

  toggle() {
    const newMode = this.modeValue === 'dark' ? 'light' : 'dark'
    this.modeValue = newMode
    this.applyTheme(newMode)

    // Save to cookie
    document.cookie = `theme=${newMode};path=/;max-age=31536000`

    // Update meta theme color
    const metaTheme = document.querySelector('meta[name="theme-color"]')
    if (metaTheme) {
      metaTheme.content = newMode === 'dark' ? '#030712' : '#ffffff'
    }
  }

  applyTheme(mode) {
    const html = document.documentElement

    if (mode === 'light') {
      html.classList.add('light')
      html.classList.remove('dark')
    } else {
      html.classList.add('dark')
      html.classList.remove('light')
    }
  }
}
