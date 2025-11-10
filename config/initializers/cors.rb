# Be sure to restart your server when you modify this file.

# Handle Cross-Origin Resource Sharing (CORS) for API requests
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Development environment
    origins "localhost:3000", "localhost:8080", "localhost:3001",
            "127.0.0.1:3000", "127.0.0.1:8080", "127.0.0.1:3001",
            "http://localhost:3000", "http://localhost:8080", "http://localhost:3001",
            "http://127.0.0.1:3000", "http://127.0.0.1:8080", "http://127.0.0.1:3001"

    resource "/api/*",
      headers: :any,
      methods: [ :get, :post, :put, :patch, :delete, :options, :head ],
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
