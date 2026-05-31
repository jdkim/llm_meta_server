# Integration guide — connecting a new service to `llm_meta_server`

This document is the contract for any consumer service (in-house or
third-party) that wants to call this meta-server's JSON API on behalf of
end users. Follow it once per consumer; you'll get unified user identity
(same `User` row across consumers), per-user MCP/API-key isolation, and a
stable refresh-token-driven session that doesn't bother users every hour.

The meta-server itself stays stateless w.r.t. consumers — there's no
registration flow, no client-secret to rotate. Trust is delegated to
Google's signature on each user's ID token.

---

## Architecture (one sentence)

**Each consumer service runs its own Google Sign-In, captures the user's
ID token + refresh token, forwards the ID token as `Authorization: Bearer
<id_token>` on every API call, and refreshes the ID token via Google
before it expires.** The meta-server verifies the JWT signature against
Google's public keys and resolves the user via the `sub` claim.

```
                Google                                    llm_meta_server
                  │                                              │
                  │ id_token + refresh_token                     │
                  ▼                                              │
            ┌──────────────────┐                                 │
            │ consumer service │  ─── Authorization: Bearer ───▶ │
            │ (yours / theirs) │       (the id_token)            │
            └──────────────────┘                                 │
                  ▲                                              │
                  │ refresh when expired                         │
                  │                                              │
                  └─── refresh_token ─── POST oauth2.googleapis.com/token
```

---

## What the consumer must do

### 1. Register a Google OAuth2 client

In Google Cloud Console → APIs & Services → Credentials → Create OAuth
client ID (Web application).

- Authorized redirect URIs: `https://<your-host>/users/auth/google_oauth2/callback`
- Save the client ID + client secret as `GOOGLE_CLIENT_ID` /
  `GOOGLE_CLIENT_SECRET` in your env.

### 2. Tell the meta-server your client ID is trusted

The meta-server reads `ALLOWED_GOOGLE_CLIENT_IDS` (comma-separated) and
accepts any ID token whose `aud` matches one of them. Add your client ID
to that env var (append; don't replace existing entries).

```
ALLOWED_GOOGLE_CLIENT_IDS=existing-app.apps.googleusercontent.com,your-new-app.apps.googleusercontent.com
```

Restart the meta-server.

### 3. Run Google Sign-In in your consumer

Use the standard `omniauth-google-oauth2` gem (or the equivalent in your
stack) with these critical options:

```ruby
# config/initializers/devise.rb (or your equivalent)
config.omniauth :google_oauth2,
                ENV["GOOGLE_CLIENT_ID"],
                ENV["GOOGLE_CLIENT_SECRET"],
                {
                  scope: "email,profile,openid",
                  access_type: "offline",       # required — without this Google won't issue a refresh_token
                  include_granted_scopes: true
                }
```

`access_type: "offline"` is the **only** way Google issues a refresh
token. Without it you're back to a 1-hour-per-sign-in user experience.

### 4. Capture and store both tokens on sign-in

In your omniauth callback:

```ruby
def google_oauth2
  user = User.from_omniauth(request.env["omniauth.auth"])
  ...
end

# In your User model:
def self.from_omniauth(auth)
  user = where(email: auth.info.email).first_or_initialize(google_id: auth.uid)
  user.id_token = auth.extra.id_token
  user.id_token_expires_at = Time.at(auth.credentials.expires_at) if auth.credentials.expires_at
  # Google only emits refresh_token on the FIRST consent (per user × client).
  # On subsequent sign-ins, preserve whatever's already stored.
  user.refresh_token = auth.credentials.refresh_token if auth.credentials.refresh_token.present?
  user.save
  user
end
```

Required columns on `users`: `id_token` (text), `refresh_token` (text),
`id_token_expires_at` (datetime). Both extra columns nullable.

### 5. Refresh the ID token before each meta-server call

Don't send an expired token. Refresh first:

```ruby
def jwt_token
  return id_token if id_token.present? && Time.current < (id_token_expires_at || Time.at(0))
  return nil unless refresh_token.present?
  RefreshGoogleIdToken.call(self) ? id_token : nil
end
```

`RefreshGoogleIdToken` is a tiny service:

```ruby
class RefreshGoogleIdToken
  TOKEN_URL = "https://oauth2.googleapis.com/token"

  def self.call(user)
    return false if user.refresh_token.blank?

    response = HTTParty.post(TOKEN_URL,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" },
      body: {
        grant_type:    "refresh_token",
        refresh_token: user.refresh_token,
        client_id:     ENV["GOOGLE_CLIENT_ID"],
        client_secret: ENV["GOOGLE_CLIENT_SECRET"]
      })

    if response.success?
      body = response.parsed_response
      user.update_columns(
        id_token:            body["id_token"],
        id_token_expires_at: Time.current + body["expires_in"].to_i.seconds
      )
      true
    else
      # 400 + invalid_grant means the refresh_token was revoked (user
      # removed access in Google account settings). Clear it so we stop
      # trying and bounce them to a fresh sign-in.
      user.update_columns(refresh_token: nil, id_token: nil, id_token_expires_at: nil) if response.code == 400
      false
    end
  end
end
```

### 6. Forward the token

```ruby
HTTParty.post("#{META_SERVER_URL}/api/llm_api_keys/#{uuid}/models/#{model}/chats",
  headers: { "Authorization" => "Bearer #{user.jwt_token}", "Content-Type" => "application/json" },
  body:    { prompt: "..." }.to_json
)
```

If `user.jwt_token` returns `nil`, the refresh failed — bounce the user
to a fresh sign-in. See "Handling unrefreshable sessions" below.

---

## Handling unrefreshable sessions

`jwt_token` returns `nil` in two cases:

1. The user never had a `refresh_token` (e.g., they signed in before
   `access_type: offline` was added, or Google didn't emit one and the
   stored value was lost).
2. Google rejected the refresh — usually `invalid_grant`, meaning the user
   revoked access in their Google account.

Either way, surface a clear "Please sign in again" banner with a
re-auth link. Best practice: stash any in-progress form state (prompt
text, attached image, selected model) in `localStorage` before bouncing,
then re-hydrate after the OAuth round-trip lands them back on the page.

---

## What the meta-server gives the consumer in return

- **Per-user data isolation.** A consumer's request resolves to a
  `User` row by `sub`. That user's `LlmApiKey`s, `McpServer`s,
  favorites, and chats are scoped to them — the consumer doesn't see
  another user's data even if the consumer's code is buggy.
- **Provider abstraction.** The consumer calls one URL shape regardless
  of provider; the meta-server picks the right upstream (OpenAI,
  Anthropic, Google, Ollama) based on the model meta_id.
- **Streaming + tools + reasoning** all uniform across providers.
  See `api/chat_streams_controller.rb` for the SSE wire shape (the
  consumer just consumes a standard `text/event-stream`).
- **Public catalog endpoint.** `GET /api/llms` works without auth
  (returns the Ollama family + favorites for the signed-in user if a
  Bearer token is supplied).

---

## What the meta-server does NOT do

- **Does not store consumer secrets.** No client-secret registration. If
  a third party's Google account is compromised, only their users (the
  ones who signed in through that consumer) are affected — your users on
  other consumers are unaffected.
- **Does not manage consumer sessions.** Each consumer is responsible for
  its own session/cookie/refresh logic. The meta-server only sees Bearer
  tokens on each request.
- **Does not proxy non-LLM traffic.** Static assets, auth callbacks, UI
  routes — all belong to the consumer.

---

## Checklist for a new consumer

- [ ] Created a Google OAuth client; saved client_id + client_secret as env.
- [ ] Appended the client_id to the meta-server's `ALLOWED_GOOGLE_CLIENT_IDS`.
- [ ] Wired `omniauth-google-oauth2` with `access_type: offline`.
- [ ] Added `refresh_token` + `id_token_expires_at` columns to `users`.
- [ ] Capture both in `User.from_omniauth`; preserve existing
      `refresh_token` when Google doesn't re-emit one.
- [ ] Implemented `RefreshGoogleIdToken` service + auto-refresh in
      `User#jwt_token`.
- [ ] UX path for `jwt_token == nil` (banner + re-auth link).
- [ ] Forward `Authorization: Bearer <id_token>` on every API call.
