class Admin::ReportsController < Admin::BaseController
  before_action :set_report, only: [:show, :edit, :update, :destroy, :publish]

  def index
    @reports = Report.includes(:game).order(created_at: :desc).limit(50)
  end

  def new
    @report = Report.new(game_id: params[:game_id])
    @games = upcoming_games
  end

  def create
    @report = Report.new(report_params)
    @report.status = "draft"

    if @report.save
      redirect_to admin_reports_path, notice: "Report created"
    else
      @games = upcoming_games
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @games = upcoming_games
  end

  def update
    if @report.update(report_params)
      redirect_to admin_reports_path, notice: "Report updated"
    else
      @games = upcoming_games
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @report.destroy
    redirect_to admin_reports_path, notice: "Report deleted"
  end

  def publish
    @report.publish!
    redirect_to admin_reports_path, notice: "Report published!"
  end

  private

  def set_report
    @report = Report.find(params[:id])
  end

  def report_params
    params.require(:report).permit(:game_id, :title, :content, :pick, :confidence, :free)
  end

  def upcoming_games
    Game.where("game_date >= ?", Date.current)
        .order(:game_date)
        .limit(30)
  end
end
