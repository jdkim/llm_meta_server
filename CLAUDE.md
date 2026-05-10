# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LLM Meta-Server — a Rails 8.0 API + web UI that provides a unified interface for multiple LLM providers (OpenAI, Anthropic, Google Gemini, Ollama) through a single API. Users register encrypted API keys and call any supported model via one endpoint. Also integrates MCP (Model Context Protocol) servers for tool calling.

## Common Commands

```bash
bin/dev                          # Start dev server (web + Tailwind CSS watch via Foreman)
bin/spec                         # Run all RSpec tests
bin/spec spec/path/file_spec.rb  # Run a single test file
bin/rubocop                      # Lint (rubocop-rails-omakase style)
bin/rubocop -A                   # Auto-fix lint issues
bin/brakeman --no-pager          # Security scan
bin/rails db:test:prepare        # Prepare test database
bin/rails db:setup               # Create DB + migrate + seed
```

CI runs: RuboCop, Brakeman, importmap audit, RSpec (in that order).

## Architecture

### Dual Interface

The app serves both a **web UI** (Devise/OAuth, standard Rails controllers with Hotwire/Turbo) and a **JSON API** (namespace `Api::`, inherits from `ApiController`). API authentication uses Google ID tokens via Bearer header; web UI uses Devise sessions with Google OAuth2.

### Key Flow: Chat Completion

`POST /api/llm_api_keys/:uuid/models/:name/chats` is the core endpoint.

1. `Api::ChatsController` authenticates via Google ID token, resolves the user's `LlmApiKey` by UUID
2. `LlmModelMap.fetch!` maps the friendly model name to the provider-specific model ID
3. `LlmRbFacade.call!` creates an `LLM::Session` (from the `llm.rb` gem) and executes the chat
4. If MCP `tool_ids` are passed, `McpToolAdapter` converts MCP tool schemas to `llm.rb` function format; tool calls are executed and results fed back to the LLM

### Services (`app/services/`)

- **LlmRbFacade** — Facade over the `llm.rb` gem. Handles provider client creation, chat execution, and tool call loops. Entry point: `LlmRbFacade.call!`
- **ApiKeyEncrypter / ApiKeyDecrypter** — AWS KMS encryption for stored API keys
- **GoogleIdTokenVerifier** — Validates Google ID tokens; supports multiple client IDs via `ALLOWED_GOOGLE_CLIENT_IDS` env var
- **McpClient** — JSON-RPC 2.0 client for MCP servers (supports SSE responses)
- **McpToolAdapter** — Converts MCP tool schemas to `llm.rb` function schemas
- **McpToolFetcher** — Fetches available tools from registered MCP servers

### Models

- **User** has_many `LlmApiKey`, has_many `McpServer`
- **LlmApiKey** — per-user encrypted API credentials with UUID for API access. Uses `EncryptableApiKey` concern for encryption lifecycle
- **Llm** has_many `LlmModel` — platform definitions (openai, anthropic, google, ollama)
- **LlmModelMap** — constants-based mapping from friendly names to provider model IDs. Ollama models are special-cased (no API key required)
- **McpServer** has_many `McpTool` — user-registered MCP servers

### Controllers

- **ApiController** — base for all API controllers. Handles Google ID token auth, rescues JWT/auth errors
- Web controllers inherit from `ApplicationController` (Devise session auth)
- API controllers live under `app/controllers/api/`

## Environment Variables

Required: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `KMS_KEY_ID`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `ALLOWED_GOOGLE_CLIENT_IDS`. See `.env` for full list.

## Tech Stack

Ruby 3.4.9, Rails 8.0.3, SQLite3, Puma, Hotwire (Turbo + Stimulus), Tailwind CSS, Devise + OmniAuth, `llm.rb` gem, AWS KMS, RSpec, RuboCop (omakase).
