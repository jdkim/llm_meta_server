# Be sure to restart your server when you modify this file.

# Handle Cross-Origin Resource Sharing (CORS) for API requests
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Development environment
    origins "http://localhost:3001",
            "http://127.0.0.1:3001",
            # PubDictionaries dev — Tier-1 chat-in-page pilot on text_annotation view.
            # Local loopback (developer on the dev box) + the public TLS-terminated
            # hostname (developer's laptop via https://test2.pubannotation.org).
            "http://localhost:6000",
            "http://127.0.0.1:6000",
            "https://test2.pubannotation.org"

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
