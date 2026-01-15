class ScheduleController < ApplicationController
  def index
    # KST timezone
    Time.zone = "Asia/Seoul"

    # Date navigation
    @selected_date = if params[:date].present?
      Date.parse(params[:date])
    else
      Date.current
    end

    @yesterday = @selected_date - 1.day
    @tomorrow = @selected_date + 1.day

    # Get games for selected date (KST)
    start_of_day = @selected_date.in_time_zone("Asia/Seoul").beginning_of_day
    end_of_day = @selected_date.in_time_zone("Asia/Seoul").end_of_day

    now = Time.current.in_time_zone("Asia/Seoul")

    @games = current_sport.games
                          .where(game_date: start_of_day..end_of_day)
                          .order(:game_date)
                          .to_a

    # Sort: upcoming first, then live, then finished
    @games = @games.sort_by do |game|
      game_time = game.game_date.in_time_zone("Asia/Seoul")
      game_end_estimate = game_time + 2.5.hours # NBA game ~2.5 hours

      if now < game_time
        [0, game_time] # Upcoming - sort by time
      elsif now >= game_time && now < game_end_estimate
        [1, game_time] # Live
      else
        [2, game_time] # Finished
      end
    end

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

  def team
    @team = params[:team]
    @games = current_sport.games
                          .where("home_abbr = ? OR away_abbr = ?", @team, @team)
                          .order(:game_date)

    @b2b_count = @games.where("schedule_note LIKE ?", "%B2B%").count
    @three_in_four = @games.where("schedule_note LIKE ?", "%3in4%").count
    @upcoming_games = @games.where("game_date >= ?", Date.current).limit(20)
  end
end
