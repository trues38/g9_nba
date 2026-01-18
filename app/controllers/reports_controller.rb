class ReportsController < ApplicationController
  def index
    @page = (params[:page] || 1).to_i
    @per_page = 20
    reports = current_sport&.reports&.published || Report.none
    @total_count = reports.count
    @reports = reports.offset((@page - 1) * @per_page).limit(@per_page)
    @free_reports = reports.where(free: true)
    @premium_reports = reports.where(free: false)
  end

  def show
    @report = Report.find(params[:id])

    # Premium reports require authentication
    unless @report.free? || premium_user?
      flash[:alert] = "This report requires a premium subscription"
      redirect_to reports_path(sport: params[:sport])
    end
  end

  private

  def premium_user?
    # Check session for premium authentication
    # For now, admin users get premium access
    session[:admin_authenticated] || session[:premium_authenticated]
  end
end
