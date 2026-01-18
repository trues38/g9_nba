class ScheduleController < ApplicationController
  def index
    Time.use_zone("Asia/Seoul") do
      # Date navigation with safe parsing
      @selected_date = parse_date_safely(params[:date]) || Date.current
      @yesterday = @selected_date - 1.day
      @tomorrow = @selected_date + 1.day

      # Get games for selected date (KST)
      start_of_day = @selected_date.in_time_zone("Asia/Seoul").beginning_of_day
      end_of_day = @selected_date.in_time_zone("Asia/Seoul").end_of_day

      @games = current_sport.games
                            .where(game_date: start_of_day..end_of_day)
                            .order(:game_date)

      # Filter by edge type
      @filter = params[:filter] || "all"
      case @filter
      when "b2b"
        @games = @games.where("schedule_note LIKE ?", "%B2B%")
      when "3in4"
        @games = @games.where("schedule_note LIKE ?", "%3in4%")
      when "edge"
        @games = @games.where.not(schedule_note: [nil, ""])
      end

      # Stats for the day
      @total_games = current_sport.games.where(game_date: start_of_day..end_of_day).count
      @edge_games = current_sport.games.where(game_date: start_of_day..end_of_day).where.not(schedule_note: [nil, ""]).count
    end
  end

  def team
    Time.use_zone("Asia/Seoul") do
      @team = params[:team]
      @games = current_sport.games
                            .where("home_abbr = ? OR away_abbr = ?", @team, @team)
                            .order(:game_date)

      @b2b_count = @games.where("schedule_note LIKE ?", "%B2B%").count
      @three_in_four = @games.where("schedule_note LIKE ?", "%3in4%").count
      @upcoming_games = @games.where("game_date >= ?", Date.current).limit(20)
    end
  end

  private

  def parse_date_safely(date_string)
    return nil if date_string.blank?
    Date.parse(date_string)
  rescue ArgumentError, TypeError
    nil
  end
end
