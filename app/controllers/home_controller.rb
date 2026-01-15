class HomeController < ApplicationController
  def index
    return unless current_sport

    @games = current_sport.games.today.limit(10)

    # If no games today, show upcoming
    if @games.empty?
      @games = current_sport.games.upcoming.limit(5)
      @showing_upcoming = true
    end

    @recent_reports = current_sport.reports.published.limit(5)
    @recent_insights = current_sport.insights.published.limit(5)

    # Upcoming games with schedule edge for the Edge Alert section
    @edge_games = current_sport.games
                               .where("game_date >= ?", Date.current)
                               .where.not(schedule_note: [nil, ""])
                               .order(:game_date)
                               .limit(3)
  end
end
