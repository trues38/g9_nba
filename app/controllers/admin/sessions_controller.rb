class Admin::SessionsController < Admin::BaseController
  def new
    # Login page
    redirect_to admin_reports_path if session[:admin_authenticated]
  end

  def create
    admin_token = ENV["ADMIN_TOKEN"]

    if admin_token.blank?
      Rails.logger.error "ADMIN_TOKEN environment variable not set"
      flash.now[:alert] = "Admin login not configured"
      render :new, status: :service_unavailable
      return
    end

    if params[:password].present? && ActiveSupport::SecurityUtils.secure_compare(params[:password], admin_token)
      session[:admin_authenticated] = true
      redirect_to admin_reports_path, notice: "Logged in successfully"
    else
      flash.now[:alert] = "Invalid password"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    session[:admin_authenticated] = nil
    redirect_to admin_login_path, notice: "Logged out"
  end
end
