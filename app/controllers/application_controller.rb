class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  stale_when_importmap_changes

  before_action :set_locale
  before_action :set_current_sport
  helper_method :current_sport, :sports

  private

  def set_locale
    I18n.locale = params[:locale] || cookies[:locale] || I18n.default_locale
    cookies[:locale] = I18n.locale if params[:locale].present?
  end

  def default_url_options
    { locale: I18n.locale }
  end

  def set_current_sport
    @current_sport = Sport.find_by(slug: params[:sport]) || Sport.find_by(slug: "basketball")
  end

  def current_sport
    @current_sport
  end

  def sports
    @sports ||= Sport.active
  end
end
