class Api::BaseController < ActionController::API
  before_action :authenticate_api_token!

  private

  def authenticate_api_token!
    token = request.headers["Authorization"]&.gsub(/^Bearer\s+/, "")

    unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, api_token)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  def api_token
    ENV.fetch("API_TOKEN") { Rails.application.credentials.dig(:api, :token) || "gate9_api_secret_token" }
  end
end
