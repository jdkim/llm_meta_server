# LLM API Call Meta-Server

A unified meta-server application that enables users to manage and switch between multiple Large Language Model (LLM) providers through a single interface.

## Overview

Large Language Models (LLMs) come in two main categories: free/open-source and commercial. Depending on your specific task requirements, you may achieve satisfactory results with free LLMs, while other tasks may require commercial LLM services to meet quality expectations.

This application serves as an **LLM API Call Meta-server** that:
- Allows users to register API keys for multiple LLM providers
- Provides a unified API interface for interacting with different LLMs
- Enables seamless switching between LLM providers based on task requirements
- Supports both free and commercial LLM services

### Supported LLM Providers

- **OpenAI** - Commercial LLM service (GPT models)
- **Anthropic** - Commercial LLM service (Claude models)
- **Google Gemini** - Commercial LLM service (Gemini models)
- **Ollama** - Free/open-source local LLM runtime

## System Requirements

### Ruby Version
- Ruby 3.4.5 (or compatible version as specified in `.ruby-version`)

### Middleware Dependencies

This application is built with Rails 8.0 and uses the following key dependencies:

- **Database**: SQLite 3 (>= 2.1)
- **Web Server**: Puma
- **Authentication**: Devise with OAuth support (Google OAuth2)
- **Asset Pipeline**: Propshaft
- **Frontend**: 
  - Hotwire (Turbo & Stimulus)
  - Tailwind CSS
  - Import maps for JavaScript
- **Background Jobs**: Solid Queue (database-backed)
- **Caching**: Solid Cache (database-backed)
- **WebSockets**: ActionCable with async adapter
- **LLM Interface**: llm.rb gem
- **Encryption**: AWS KMS for API key encryption

No external middleware services (Redis, PostgreSQL, etc.) are required for basic operation as Rails 8.0 uses Solid Queue and Solid Cache with SQLite.

## Environment Setup

### Prerequisites

1. Install Ruby 3.4.5 (or use a Ruby version manager like rbenv or rvm)
2. Install SQLite 3
3. Install Node.js (for asset compilation)

### Installation Steps

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd llm_meta_server
   ```

2. **Install dependencies**
   ```bash
   bundle install
   ```

3. **Set up environment variables**
   
   Create a `.env` file in the root directory with the following variables:
   ```bash
   # Google OAuth (for user authentication)
   GOOGLE_CLIENT_ID=your_google_client_id
   GOOGLE_CLIENT_SECRET=your_google_client_secret
   
   # AWS KMS (for API key encryption)
   AWS_ACCESS_KEY_ID=your_aws_access_key
   AWS_SECRET_ACCESS_KEY=your_aws_secret_key
   AWS_REGION=your_aws_region
   AWS_KMS_KEY_ID=your_kms_key_id
   ```

4. **Set up the database**
   ```bash
   bin/rails db:create
   bin/rails db:migrate
   ```

5. **Start the development server**
   ```bash
   bin/dev
   ```
   
   This command starts all development services defined in `Procfile.dev`, including:
   - Rails web server (available at `http://localhost:3000`)
   - Tailwind CSS watch mode (for automatic stylesheet compilation)
   
   All services will run in a single terminal with color-coded output.

### Alternative: Using Rails commands separately

If you prefer to run services separately:

```bash
# Run the web server
bin/rails server

# Run Tailwind CSS watch (in a separate terminal)
bin/rails tailwindcss:watch

# Run Solid Queue (in a separate terminal, if needed)
bin/jobs
```

## Running Tests

This project uses RSpec for testing.

```bash
# Run all tests
bundle exec rspec

# Run specific test file
bundle exec rspec spec/models/llm_api_key_spec.rb

# Run tests with coverage
COVERAGE=true bundle exec rspec
```

## Usage

### User Authentication

1. Navigate to the application home page
2. Sign in using your Google account
3. After authentication, you'll be redirected to your user profile

### Managing API Keys

1. From your profile page, navigate to "LLM API Keys"
2. Add API keys for your preferred LLM providers:
   - Select the provider (OpenAI, Anthropic, Google, or Ollama)
   - Enter your API key
   - Add an optional description
3. Each API key will be assigned a unique UUID for API access

### Making API Calls

Use the unified API endpoint to make chat completion requests:

```bash
POST /api/llm_api_keys/:uuid/models/:model_name/chats
```

**Parameters:**
- `uuid`: The UUID of your registered API key
- `model_name`: The model name (e.g., "gpt-4", "claude-3-opus", "gemini-pro")
- `prompt`: Your chat prompt (in request body)

**Authentication:**
API calls require a JWT token obtained after user authentication.

**Example Request:**
```bash
curl -X POST "https://your-server.com/api/llm_api_keys/{uuid}/models/gpt-4/chats" \
  -H "Authorization: Bearer {your_jwt_token}" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Hello, how are you?"}'
```

## Security

- API keys are encrypted using AWS KMS before storage
- User authentication is handled through OAuth 2.0 (Google)
- API access requires JWT token authentication
- All sensitive configuration is managed through environment variables

## Development

### Code Style

This project follows Ruby style guidelines enforced by RuboCop:

```bash
# Run RuboCop
bin/rubocop

# Auto-fix issues
bin/rubocop -A
```

### Security Scanning

Run Brakeman to check for security vulnerabilities:

```bash
bin/brakeman
```

## License

[Specify your license here]

## Contributing

[Add contributing guidelines if applicable]
