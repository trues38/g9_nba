class ReportsController < ApplicationController
  def index
    @reports = current_sport&.reports&.published || Report.none
  end

  def show
    @report = Report.find(params[:id])
  end
end
