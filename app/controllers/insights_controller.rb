class InsightsController < ApplicationController
  def index
    @insights = current_sport&.insights&.published || Insight.none
  end

  def show
    @insight = Insight.find(params[:id])
  end
end
