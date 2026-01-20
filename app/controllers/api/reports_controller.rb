class Api::ReportsController < Api::BaseController
  # POST /api/reports
  # Creates and optionally publishes a report
  #
  # Headers:
  #   Authorization: Bearer <API_TOKEN>
  #
  # Body (JSON):
  #   {
  #     "game_id": 123,
  #     "title": "LAL vs GSW Analysis",
  #     "content": "## Analysis\n\n...",
  #     "pick": "LAL -3.5",
  #     "pick_type": "spread",       # spread, total, moneyline
  #     "pick_line": -3.5,
  #     "pick_side": "home",         # home, away, over, under
  #     "stake": 1.0,
  #     "confidence": "★★★★☆",
  #     "analyst_consensus": "4/5",
  #     "free": false,
  #     "publish": true              # auto-publish if true
  #   }
  #
  def create
    @report = Report.new(report_params)
    @report.status = "draft"

    if @report.save
      @report.publish! if params[:publish].to_s == "true"

      render json: {
        success: true,
        report: {
          id: @report.id,
          title: @report.title,
          status: @report.status,
          published_at: @report.published_at,
          url: report_url(@report)
        }
      }, status: :created
    else
      render json: {
        success: false,
        errors: @report.errors.full_messages
      }, status: :unprocessable_entity
    end
  end

  # GET /api/reports
  # List recent reports
  def index
    @reports = Report.order(created_at: :desc).limit(params[:limit] || 20)

    render json: {
      reports: @reports.map { |r|
        {
          id: r.id,
          title: r.title,
          game_id: r.game_id,
          status: r.status,
          result: r.result,
          published_at: r.published_at
        }
      }
    }
  end

  # GET /api/reports/:id
  def show
    @report = Report.find(params[:id])

    render json: {
      report: {
        id: @report.id,
        title: @report.title,
        content: @report.content,
        pick: @report.pick,
        pick_type: @report.pick_type,
        pick_line: @report.pick_line,
        pick_side: @report.pick_side,
        confidence: @report.confidence,
        status: @report.status,
        result: @report.result,
        published_at: @report.published_at
      }
    }
  end

  # PATCH /api/reports/:id/result
  # Record the result of a pick
  #
  # Body: { "result": "win" }  # win, loss, push
  #
  def record_result
    @report = Report.find(params[:id])

    if @report.update(result: params[:result])
      render json: { success: true, result: @report.result }
    else
      render json: { success: false, errors: @report.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def report_params
    params.permit(
      :game_id, :title, :content, :pick, :confidence, :free,
      :pick_type, :pick_line, :pick_side, :stake, :analyst_consensus,
      structured_data: {}
    )
  end

  def report_url(report)
    sport = report.game&.sport&.slug || "basketball"
    "#{request.base_url}/#{sport}/reports/#{report.id}"
  end
end
