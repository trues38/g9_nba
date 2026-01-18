class Admin::StatsController < Admin::BaseController
  def index
    @sport = Sport.find_by(slug: params[:sport]) || Sport.find_by(slug: "basketball")
    reports = @sport.reports.published

    # Overall stats
    @overall_stats = Report.stats(reports)

    # By pick type
    @stats_by_type = Report.stats_by_pick_type(reports)

    # By consensus level
    @stats_by_consensus = Report.stats_by_consensus(reports)

    # Recent results (last 30 days)
    recent = reports.where("published_at >= ?", 30.days.ago)
    @recent_stats = Report.stats(recent)

    # Monthly breakdown
    @monthly_stats = Report.stats_by_month(reports)

    # Pending results to record
    @pending_reports = reports.pending_result
                              .joins(:game)
                              .where("games.game_date < ?", Time.current)
                              .order("games.game_date DESC")
                              .limit(20)
  end

  def record_result
    @report = Report.find(params[:id])

    home_score = params[:home_score].to_i
    away_score = params[:away_score].to_i

    # Auto-calculate or use manual result
    result = if params[:result].present?
               params[:result]
             else
               @report.calculate_result_from_scores(home_score, away_score)
             end

    if result && @report.record_result!(result, home_score: home_score, away_score: away_score, note: params[:note])
      redirect_to admin_stats_path, notice: "Result recorded: #{result.upcase}"
    else
      redirect_to admin_stats_path, alert: "Failed to record result"
    end
  end

  def bulk_sync_results
    # Sync results from finished games
    synced = 0

    Report.published.pending_result.includes(:game).find_each do |report|
      game = report.game
      next unless game.status == "finished" && game.home_score.present? && game.away_score.present?
      next unless report.pick_type.present? && report.pick_line.present?

      result = report.calculate_result_from_scores(game.home_score, game.away_score)
      if result
        report.record_result!(result, home_score: game.home_score, away_score: game.away_score)
        synced += 1
      end
    end

    redirect_to admin_stats_path, notice: "Synced #{synced} results from finished games"
  end
end
