Rails.application.routes.draw do
  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks",
    sessions: "users/sessions"
  }

  # Custom session routes (all defined within Devise scope)
  devise_scope :user do
    delete "/logout", to: "users/sessions#destroy", as: :user_logout
    post "/logout", to: "users/sessions#destroy"
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # User profile routes
  resources :user, only: [ :show ] do
    resources :llm_api_keys, only: [ :index, :create, :update, :destroy ]
  end

  get "/llm_api_keys", to: "token_authentication#llm_api_keys"

  # Defines the root path route ("/")
  root "home#index"
end
