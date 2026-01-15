Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Root → Schedule (메인)
  root "schedule#index"

  # Main tabs
  get "profile", to: "profile#index"

  # Admin namespace (must be before sport-scoped routes!)
  namespace :admin do
    resources :sports
    resources :reports do
      post :publish, on: :member
    end
    resources :insights
    resources :games, only: [:index, :show]
  end

  # Sport-scoped resources (after admin to avoid conflicts)
  scope "/:sport", defaults: { sport: "basketball" }, constraints: { sport: /basketball|baseball|soccer|football|hockey/ } do
    resources :reports, only: [:index, :show]
    resources :insights, only: [:index, :show]
    resources :schedule, only: [:index], as: :schedule_index
    get "schedule/team/:team", to: "schedule#team", as: :schedule_team
    get "/", to: "schedule#index", as: :sport_home
  end
end
