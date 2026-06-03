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

  # SSO landing — meant to be deep-linked from sister services (chat
  # service, future services, third-party clients). If the visitor
  # already has a hub session, redirect them to `?return_to=` or root.
  # Otherwise render a page that auto-submits the Google OAuth form so
  # the user lands signed-in after one Google-session-resumed round
  # trip (~1-2 seconds, no manual click).
  get "/sso", to: "sso#show"

  # Super-user dashboard (gated by User#super_user?).
  get "/admin", to: "admin#index"

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # LLMs list route
  resources :llms, only: [ :index ]

  # Per-user favorite-models management
  resources :models, only: [ :index ] do
    member do
      patch :toggle_favorite
      patch :set_default
    end
  end

  # User profile routes
  resources :user, only: [ :show ] do
    resources :llm_api_keys, only: [ :index, :create, :update, :destroy ]
    resources :mcp_servers, only: [ :index, :create, :update, :destroy ] do
      member do
        patch :toggle
        patch :toggle_public
      end
      resources :mcp_tools, only: [ :index ] do
        member do
          patch :toggle
        end
      end
    end
  end

  namespace :api do
    # Super-user JSON stats — consumed by sister services (e.g. the
    # chat service's combined /admin page) to render a unified view.
    get "/admin/stats", to: "admin#stats"

    # LLM services and models information
    resources :llms, only: [ :index ]

    resources :llm_api_keys, only: [ :index ], param: :uuid do
      resources :models, only: [], param: :name do # These constraints allow to include dot in model_name
        resources :chats, only: [ :create ]
        resources :chat_streams, only: [ :create ]
      end
    end

    resources :mcp_servers, only: [ :index, :create, :update, :destroy ], param: :uuid do
      member do
        patch :toggle
        patch :toggle_public
      end
      resources :tools, only: [ :index ], controller: "mcp_tools" do
        member do
          patch :toggle
        end
      end
    end
  end

  # Defines the root path route ("/")
  root "home#index"
end
