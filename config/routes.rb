Rails.application.routes.draw do
  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Root → Schedule (메인)
  root "schedule#index"

  # Main tabs
  get "profile", to: "profile#index"

  # Admin namespace (must be before sport-scoped routes!)
  namespace :admin do
    # Auth
    get "login", to: "sessions#new", as: :login
    post "login", to: "sessions#create"
    delete "logout", to: "sessions#destroy", as: :logout

    resources :sports
    resources :reports do
      post :publish, on: :member
    end
    resources :insights
    resources :games, only: [:index, :show]

    # ROE-2 YouTube Insights
    resources :roe2, only: [:index, :new, :create] do
      collection do
        post :extract
      end
    end

    # Stats / Performance tracking
    get "stats", to: "stats#index"
    post "stats/record/:id", to: "stats#record_result", as: :record_result
    post "stats/sync", to: "stats#bulk_sync_results", as: :bulk_sync_results
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
