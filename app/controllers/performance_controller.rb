class PerformanceController < ApplicationController
  # Public performance stats (when ready to expose)
  # Enable by adding route: get "performance", to: "performance#index"

  def index
    # Only show stats if enabled
    unless ENV["PUBLIC_STATS_ENABLED"] == "true"
      render plain: "Coming soon", status: :service_unavailable
      return
    end

    reports = current_sport&.reports&.published&.with_result || Report.none

    @overall_stats = Report.stats(reports)
    @stats_by_type = Report.stats_by_pick_type(reports)
    @stats_by_consensus = Report.stats_by_consensus(reports)

    # Recent picks with results
    @recent_picks = reports.order(published_at: :desc).limit(20)
  end

  # JSON API for embedding or external use
  def api
    unless ENV["PUBLIC_STATS_ENABLED"] == "true"
      render json: { error: "Not available" }, status: :service_unavailable
      return
    end

    reports = current_sport&.reports&.published&.with_result || Report.none

    render json: {
      overall: Report.stats(reports),
      by_type: Report.stats_by_pick_type(reports),
      by_consensus: Report.stats_by_consensus(reports),
      updated_at: Time.current.iso8601
    }
  end
end
