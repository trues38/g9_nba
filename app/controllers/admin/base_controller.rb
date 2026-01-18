class Admin::BaseController < ApplicationController
  before_action :authenticate_admin!
  layout "admin"

  private

  def authenticate_admin!
    # Skip auth for login page
    return if controller_name == "sessions"

    unless session[:admin_authenticated]
      redirect_to admin_login_path
    end
  end
end
