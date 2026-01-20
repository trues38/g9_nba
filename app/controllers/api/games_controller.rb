class Api::GamesController < Api::BaseController
  # GET /api/games
  # List games with optional filters
  #
  # Params:
  #   filter: today, tomorrow, week, all (default: tomorrow)
  #   date: specific date (YYYY-MM-DD)
  #
  def index
    @games = filtered_games

    render json: {
      games: @games.map { |g|
        {
          id: g.id,
          away_team: g.away_team,
          home_team: g.home_team,
          away_abbr: g.away_abbr,
          home_abbr: g.home_abbr,
          game_date: g.game_date,
          home_spread: g.home_spread,
          away_spread: g.away_spread,
          total_line: g.total_line,
          home_edge: g.home_edge,
          away_edge: g.away_edge,
          reports_count: g.reports.count
        }
      }
    }
  end

  # GET /api/games/:id
  def show
    @game = Game.find(params[:id])

    render json: {
      game: {
        id: @game.id,
        away_team: @game.away_team,
        home_team: @game.home_team,
        away_abbr: @game.away_abbr,
        home_abbr: @game.home_abbr,
        game_date: @game.game_date,
        home_spread: @game.home_spread,
        away_spread: @game.away_spread,
        total_line: @game.total_line,
        home_edge: @game.home_edge,
        away_edge: @game.away_edge,
        venue: @game.venue,
        reports: @game.reports.map { |r| { id: r.id, title: r.title, status: r.status } }
      }
    }
  end

  private

  def filtered_games
    base_scope = Game.includes(:reports).order(:game_date)

    if params[:date].present?
      date = Date.parse(params[:date])
      base_scope.where("DATE(game_date) = ?", date)
    else
      case params[:filter]
      when "today"
        base_scope.where("DATE(game_date) = ?", Date.current)
      when "week"
        base_scope.where("game_date BETWEEN ? AND ?", Date.current, Date.current + 7.days)
      when "all"
        base_scope.where("game_date >= ?", Date.current)
      else # tomorrow (default)
        base_scope.where("DATE(game_date) = ?", Date.current + 1.day)
      end
    end
  end
end
