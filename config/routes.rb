Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Root → Schedule (메인)
  root "schedule#index"

  # Main tabs
  get "profile", to: "profile#index"

  # Sport-scoped resources
  scope "/:sport", defaults: { sport: "basketball" } do
    resources :reports, only: [:index, :show]
    resources :insights, only: [:index, :show]
    resources :schedule, only: [:index], as: :schedule_index
    get "schedule/team/:team", to: "schedule#team", as: :schedule_team
    get "/", to: "schedule#index", as: :sport_home
  end

  # Admin namespace (later)
  namespace :admin do
    resources :sports
    resources :reports
    resources :insights
    resources :games
  end
end
