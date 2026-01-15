class Admin::BaseController < ApplicationController
  before_action :authenticate_admin!
  layout "admin"

  private

  def authenticate_admin!
    # Simple token auth - check ?token= param or session
    admin_token = ENV.fetch("ADMIN_TOKEN", "gate9admin2025")

    if params[:token].present?
      if params[:token] == admin_token
        session[:admin_authenticated] = true
        redirect_to request.path and return # Remove token from URL
      else
        render plain: "Invalid token", status: :unauthorized
      end
    elsif !session[:admin_authenticated]
      render plain: "Admin access required. Add ?token=YOUR_TOKEN", status: :unauthorized
    end
  end
end
