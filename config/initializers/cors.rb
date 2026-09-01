# Be sure to restart your server when you modify this file.

# Handle Cross-Origin Resource Sharing (CORS) for API requests
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Development environment — llm_meta_chat_dev + browser widgets embedded
    # on host sites that call the hub's anon API endpoints directly (level-1
    # widget flow). Add new widget-embedding origins here as they land.
    origins "http://localhost:3001",
            "http://127.0.0.1:3001",
            "https://test2.pubannotation.org",   # PubDictionaries dev, hosts the level-1 widget
            "https://pubdictionaries.org"        # PubDictionaries prod (forward-looking)

    resource "/api/*",
      headers: :any,
      methods: [ :get, :post ],
      expose: [ "Content-Type", "Authorization" ],
      credentials: false  # Corresponds to credentials: 'omit'
  end

  # Production environment (add as needed)
  # allow do
  #   origins 'https://yourdomain.com'
  #   resource '/api/*',
  #     headers: :any,
  #     methods: [:get, :post, :put, :patch, :delete, :options, :head],
  #     expose: ['Content-Type', 'Authorization'],
  #     credentials: false
  # end
end
