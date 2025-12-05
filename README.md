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

- **OpenAI** - Commercial LLM service (GPT models: GPT-4o, GPT-4o Mini, GPT-4 Turbo, GPT-3.5 Turbo)
- **Anthropic** - Commercial LLM service (Claude models: Claude Sonnet 4.5, Claude Haiku 4.5, Claude Opus 4.1, Claude Sonnet 3.7, Claude 3.5 Haiku, Claude 3 Haiku)
- **Google** - Commercial LLM service (Gemini models: Gemini 2.5 Pro, Gemini 2.5 Flash, Gemini 2.0 Flash)
- **Ollama** - Free/open-source local LLM runtime (no API key required)

## System Requirements

### Ruby Version
- Ruby 3.4.7 (or compatible version as specified in `.ruby-version`)

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
- **LLM Interface**: llm.rb gem
- **Encryption**: AWS KMS for API key encryption
- **HTTP Client**: HTTParty for external API calls
- **Token Verification**: Google Auth library for ID token verification
- **CORS**: Rack::Cors for cross-origin resource sharing

No external middleware services (Redis, PostgreSQL, etc.) are required for basic operation.

## Environment Setup

### Prerequisites

1. Install Ruby 3.4.7 (or use a Ruby version manager like rbenv or rvm)
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
   
   Create a `.env` file in the root directory with the following required variables:
   
   ```bash
   # AWS Configuration (required for API key encryption)
   AWS_ACCESS_KEY_ID=your_aws_access_key_id
   AWS_SECRET_ACCESS_KEY=your_aws_secret_access_key
   AWS_REGION=your_aws_region
   
   # AWS KMS Key for encryption (required)
   # Use Key ID format (recommended): 1234abcd-12ab-34cd-56ef-1234567890ab
   # or Alias format: alias/llm-api-meta-server-key
   KMS_KEY_ID=your_kms_key_id
   
   # Google OAuth2 Configuration (required for user authentication)
   GOOGLE_CLIENT_ID=your_google_client_id
   GOOGLE_CLIENT_SECRET=your_google_client_secret
   
   # Allowed Google Client IDs (comma-separated, required)
   # Include all Google client IDs of external services authorized to use this LLM Meta Server
   ALLOWED_GOOGLE_CLIENT_IDS=external_service_1_client_id,external_service_2_client_id
   
   # Application Host (required)
   # The base URL where your application is hosted
   APP_HOST=http://localhost:3000
   ```
   
   **Environment Variable Descriptions:**
   
   | Variable | Required | Description |
   |----------|----------|-------------|
   | `AWS_ACCESS_KEY_ID` | Yes | AWS access key for KMS encryption |
   | `AWS_SECRET_ACCESS_KEY` | Yes | AWS secret key for KMS encryption |
   | `AWS_REGION` | Yes | AWS region where your KMS key is located |
   | `KMS_KEY_ID` | Yes | AWS KMS key ID or alias for encrypting API keys |
   | `GOOGLE_CLIENT_ID` | Yes | Google OAuth2 client ID for user authentication |
   | `GOOGLE_CLIENT_SECRET` | Yes | Google OAuth2 client secret |
   | `ALLOWED_GOOGLE_CLIENT_IDS` | Yes | Comma-separated list of Google client IDs for external services authorized to use this LLM Meta Server |
   | `APP_HOST` | Yes | Base URL of your application |
   
   ### Google OAuth2 Setup Instructions
   
   To obtain the required Google OAuth2 credentials:
   
   1. **Create a Google Cloud Project** (if you don't have one):
      - Go to [Google Cloud Console](https://console.cloud.google.com/)
      - Create a new project or select an existing one
   
   2. **Enable Google+ API**:
      - Navigate to "APIs & Services" > "Library"
      - Search for "Google+ API" and enable it
   
   3. **Create OAuth 2.0 Credentials**:
      - Go to "APIs & Services" > "Credentials"
      - Click "Create Credentials" > "OAuth 2.0 Client IDs"
      - Choose "Web application" as the application type
   
   4. **Configure Authorized Redirect URIs**:
      
      Add the following redirect URIs to your OAuth client configuration:
      
      **For Development (localhost):**
      ```
      http://localhost:3000/users/auth/google_oauth2/callback
      ```
      
      **For Production:**
      ```
      https://yourdomain.com/users/auth/google_oauth2/callback
      ```
      
      Replace `yourdomain.com` with your actual production domain.
   
   5. **Get Your Credentials**:
      - After creating the OAuth client, copy the "Client ID" and "Client Secret"
      - Use these values for `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`
   
   6. **Configure Allowed Client IDs**:
      - The `ALLOWED_GOOGLE_CLIENT_IDS` should include Google client IDs of external services that are authorized to use this LLM Meta Server
      - This is different from `GOOGLE_CLIENT_ID` which is used for user authentication on this server
      - Include client IDs of all external applications/services that will consume this meta-server's API:
        ```bash
        ALLOWED_GOOGLE_CLIENT_IDS=external_app_client_id,mobile_app_client_id,web_service_client_id
        ```
   
   **Important Security Notes:**
   - Never commit OAuth credentials to version control
   - Use different OAuth clients for development and production environments
   - Regularly rotate your client secrets for production applications

4. **Set up the database**
   ```bash
   bin/rails db:setup
   ```
   
   This command creates the database, runs migrations, and loads seed data.

5. **Start the development environment**
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
```

## Database Seeding

The project provides `db/seeds.rb` to populate required master data (LLM providers and their models). The seed script is idempotent and safe to rerun.

### Run seeds (development)
```bash
bin/rails db:seed
```

### First-time setup (create DB + migrate + seed)
```bash
bin/rails db:setup
```

### Run seeds for a specific environment
```bash
RAILS_ENV=production bin/rails db:seed
```

### What gets created
- LLM platforms: OpenAI, Anthropic, Google, Ollama
- Their available models based on `LlmModelMap`

Notes:
- Ensure your database is migrated before seeding (`bin/rails db:migrate`).
- Seeding does not require API keys; it only creates platform and model records.

## Running Tests

This project uses RSpec for testing.

```bash
# Run all tests
bin/spec

# Run specific test file
bin/spec spec/models/llm_api_key_spec.rb

# Run tests with coverage
COVERAGE=true bin/spec
```

## Usage

### User Authentication

1. Navigate to the application home page
2. Sign in using your Google account
3. After authentication, you'll be redirected to your user profile

### Managing API Keys

1. From your profile page, navigate to "LLM API Keys"
2. Add API keys for your preferred LLM providers:
   - Select the provider (OpenAI, Anthropic, or Google)
   - Enter your API key
   - Add an optional description
3. Each API key will be assigned a unique UUID for API access

**Note:** Ollama does not require API key registration as it runs locally.

### Making API Calls

#### Get Available LLM Services and Models

Get a list of all available LLM services and their models:

```bash
GET /api/llms
```

**Authentication:**
Requires Google ID Token authentication.

**Example Request:**
```bash
curl -X GET "https://your-server.com/api/llms" \
  -H "Authorization: Bearer {your_google_id_token}" \
  -H "Content-Type: application/json"
```

**Example Response:**
```json
{
  "llms": [
    {
      "id": 1,
      "name": "OpenAI",
      "created_at": "2025-01-01T00:00:00.000Z",
      "updated_at": "2025-01-01T00:00:00.000Z",
      "models": [
        {
          "name": "gpt-4o",
          "display_name": "GPT-4o",
          "created_at": "2025-01-01T00:00:00.000Z",
          "updated_at": "2025-01-01T00:00:00.000Z"
        },
        {
          "name": "gpt-4o-mini",
          "display_name": "GPT-4o Mini",
          "created_at": "2025-01-01T00:00:00.000Z",
          "updated_at": "2025-01-01T00:00:00.000Z"
        }
      ]
    },
    {
      "id": 2,
      "name": "Anthropic",
      "created_at": "2025-01-01T00:00:00.000Z",
      "updated_at": "2025-01-01T00:00:00.000Z",
      "models": [
        {
          "name": "claude-sonnet-4-5",
          "display_name": "Claude Sonnet 4.5",
          "created_at": "2025-01-01T00:00:00.000Z",
          "updated_at": "2025-01-01T00:00:00.000Z"
        }
      ]
    },
    {
      "llm_type": "ollama",
      "description": "[Ollama] Local Ollama (no API key required)",
      "uuid": "ollama-local",
      "available_models": [
        {
          "label": "gpt-oss:20b",
          "value": "gpt-oss-20b"
        }
      ]
    }
  ]
}
```

#### Get Your API Keys

Get a list of your registered API keys:

```bash
GET /api/llm_api_keys
```

**Authentication:**
Requires Google ID Token authentication.

**Example Request:**
```bash
curl -X GET "https://your-server.com/api/llm_api_keys" \
  -H "Authorization: Bearer {your_google_id_token}" \
  -H "Content-Type: application/json"
```

**Example Response:**
```json
{
  "llm_api_keys": [
    {
      "uuid": "550e8400-e29b-41d4-a716-446655440000",
      "llm_type": "openai",
      "description": "[OpenAI] Production Key",
      "available_models": [
        {
          "label": "GPT-4o",
          "value": "gpt-4o"
        },
        {
          "label": "GPT-4o Mini",
          "value": "gpt-4o-mini"
        }
      ]
    },
    {
      "uuid": "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
      "llm_type": "anthropic",
      "description": "[Anthropic] Dev Key",
      "available_models": [
        {
          "label": "Claude Sonnet 4.5",
          "value": "claude-sonnet-4-5"
        }
      ]
    }
  ]
}
```

#### Make Chat Completion Requests

Use the unified API endpoint to make chat completion requests:

```bash
POST /api/llm_api_keys/:uuid/models/:model_name/chats
```

**Parameters:**
- `uuid`: The UUID of your registered API key (or "ollama-local" for Ollama)
- `model_name`: The model name (e.g., "gpt-4o", "claude-sonnet-4-5", "gemini-2-5-pro")
- `prompt`: Your chat prompt (in request body)

**Authentication:**
Requires Google ID Token authentication.

**Example Request:**
```bash
curl -X POST "https://your-server.com/api/llm_api_keys/{uuid}/models/gpt-4o/chats" \
  -H "Authorization: Bearer {your_google_id_token}" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Hello, how are you?"}'
```

**Example Response:**
```json
{
  "response": {
    "message": "Hello! I'm doing well, thank you for asking. How can I help you today?"
  }
}
```

**Note:** For Ollama (no API key required), use `uuid=ollama-local` in the API endpoint.

## Security

- API keys are encrypted using AWS KMS before storage
- User authentication is handled through OAuth 2.0 (Google)
- API access requires Google ID Token authentication
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
