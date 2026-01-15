class Admin::GamesController < Admin::BaseController
  def index
    @games = Game.where("game_date >= ?", Date.current - 1.day)
                 .order(:game_date)
                 .includes(:reports)
  end

  def show
    @game = Game.find(params[:id])
  end
end
