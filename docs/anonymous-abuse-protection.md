# Anonymous widget abuse protection

The client orchestrates `single_llm_calls → MCP call → next single_llm_calls`.
Each HTTP call is independently admitted on the server. Client limits are not a
security boundary. PostgreSQL row locking shares admission, reservations and
emergency switches across Puma workers and instances using the same database.
No additional Redis service is required.

## Defaults

| Limit | Default | Environment variable |
| --- | --- | --- |
| LLM calls per IP per rolling minute | 6 | ANONYMOUS_LLM_RATE |
| MCP calls per IP per rolling minute | 20 | ANONYMOUS_MCP_RATE |
| LLM concurrency per IP / all instances | 1 / 2 | ANONYMOUS_LLM_PER_IP / ANONYMOUS_LLM_GLOBAL |
| MCP concurrency per IP / all instances | 2 / 8 | ANONYMOUS_MCP_PER_IP / ANONYMOUS_MCP_GLOBAL |
| LLM / MCP elapsed deadline | 600 / 30 seconds | ANONYMOUS_LLM_SECONDS / ANONYMOUS_MCP_SECONDS |
| Daily inference elapsed time per IP | 1800 seconds, UTC day | ANONYMOUS_DAILY_SECONDS |
| HTTP request body | 256 KiB | ANONYMOUS_BODY_BYTES |
| Messages / content per message | 20 / 128 KiB | ANONYMOUS_MESSAGES / ANONYMOUS_MESSAGE_BYTES |
| Registered tool IDs / local schemas | 40 / 16 | ANONYMOUS_TOOLS / ANONYMOUS_LOCAL_TOOLS |
| Local schema total / tool arguments | 64 KiB / 32 KiB | ANONYMOUS_SCHEMA_BYTES / ANONYMOUS_ARGUMENT_BYTES |
| Upstream MCP response | 256 KiB | ANONYMOUS_RESULT_BYTES |
| Ollama context / output tokens | 65536 / 4096 | ANONYMOUS_NUM_CTX / ANONYMOUS_NUM_PREDICT |
| Model allowlist (catalog slugs) | glm-4-7-flash | ANONYMOUS_MODELS (comma-separated) |

Generation settings permit only `options`, `think`, `temperature`, `top_p`.
Options permit `num_ctx`, `num_predict`, `temperature`, `top_p`, `repeat_penalty`,
`seed`. Token counts must be positive integers within limits; unrestricted output
(`num_predict=-1`) and unknown options are rejected. Missing context/output
counts receive bounded defaults. Catalog defaults are validated too.

Per-tool limits default to concurrency 2, 20 calls/minute **across all IPs**,
30 seconds and 256 KiB. Override by tool name, capped at server-wide limits:

```sh
ANONYMOUS_TOOL_LIMITS='{"TogoMCP_Usage_Guide":{"concurrency":1,"rate":10,"seconds":20,"result_bytes":262144}}'
```

The existing guide (~117 KB) fits the message and result limits. Body limits
also apply to authenticated calls to these endpoints and the legacy chat endpoints, before JSON parsing,
including bodies without Content-Length. Other limits apply to anonymous calls.
An invalid bearer token does not become anonymous. MCP visibility still requires
an active tool/server with `public_to_anonymous` enabled.

**Compatibility change:** anonymous `/chats` and `/chat_streams` return 403.
Use `/single_llm_calls`; this closes the unrestricted legacy inference/tool-loop
bypass. Authenticated legacy calls retain their existing behavior.

## Apply

```sh
bundle exec rails db:migrate
# Restart the Rails/Puma process to load the middleware and proxy settings.
```

All instances must run the same configuration and share PostgreSQL and the
Rails secret key. Configure `ANONYMOUS_TRUSTED_PROXIES` with only the actual
trusted ingress CIDRs (e.g. `127.0.0.1/32,::1/128` for a local reverse proxy).
The ingress must overwrite client-supplied forwarding headers. Prevent direct
public access to Rails and Ollama. The admission key uses Rails `remote_ip`,
HMAC-hashed with the server secret; raw IPs are not stored in the usage table.

At ingress also set `client_max_body_size 256k`, header/read timeouts and an IP
request-rate limit. This rejects floods before they occupy Rails workers or DB
connections. Application middleware cannot prevent a network bandwidth flood or
slow request-body upload. For a localhost Nginx → Rails deployment:

```nginx
# http context
limit_req_zone $binary_remote_addr zone=widget_ingress:10m rate=2r/s;

# server context; same-origin widget calls /llm-meta/api/...
location /llm-meta/api/ {
    client_max_body_size 256k;
    client_body_timeout 10s;
    limit_req zone=widget_ingress burst=10 nodelay;
    limit_req_status 429;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_read_timeout 620s;
    proxy_pass http://127.0.0.1:3000/api/;
}
```

Authenticated traffic to this ingress also receives its coarse ingress limit.
The detailed per-IP limits are enforced in the application. Ensure the DB pool
has spare connections for monitor threads, in addition to controller/live
threads; exhausted/unavailable admission storage rejects new anonymous work.
The shared singleton row suits a small public widget; it serializes admission
and settlement, never inference. Admission stops at 10,000 tracked IP keys by
default to bound retained state. Large deployments need a sharded/shared store
and load testing before raising concurrency.

## Stop and resume

No public administrative endpoint is exposed. Operators with application shell
access can stop LLM and MCP independently without restarting other instances:

```sh
bundle exec rails anonymous_usage:set KIND=llm ENABLED=false ACTOR=operator REASON=incident
bundle exec rails anonymous_usage:set KIND=mcp ENABLED=false ACTOR=operator REASON=incident
bundle exec rails anonymous_usage:set KIND=llm ENABLED=true ACTOR=operator REASON=recovered
bundle exec rails anonymous_usage:set KIND=mcp ENABLED=true ACTOR=operator REASON=recovered
```

Admission, settlement (elapsed/charged seconds) and rejected API calls emit
structured log events with a hashed IP subject, without prompts, arguments or
credentials. Forward application logs to your normal persistent audit storage.

Actor/reason are mandatory; the latest 100 changes are stored in PostgreSQL and
also logged. `ANONYMOUS_LLM_ENABLED=false` / `ANONYMOUS_MCP_ENABLED=false` are
startup fail-closed switches and override the shared resume setting.

## Responses and cancellation

Invalid input: 400; body size: 413; rate/IP concurrency/daily budget: 429;
global/tool capacity, emergency stop, unavailable admission DB: 503.
Retryable admission errors include `Retry-After` (also exposed by CORS).
MCP execution deadline returns 504; oversized MCP results return 502.
Once LLM SSE starts, errors use an `error` event (`execution_timeout` or
`stopped`) without a `done` event. Clients should display the error and stop
the loop rather than retry automatically.

A monitor interrupts the actual provider/client operation, even when no chunks
arrive, and releases its execution reservation in ensure. Running work observes
shared emergency state every 250 ms, subject to DB availability. LLM client
disconnects are detected by stream writes/5-second heartbeats. MCP calls remain
bounded by their deadline even if their caller disappears. A dead worker's lease
expires after its deadline plus 5 seconds; abandoned LLM work is charged the
full reservation. Completed requests charge elapsed time, not tokens or money.
Daily budget resets at UTC midnight; an operation crossing midnight is charged
to its admission day.

Interrupting Rails HTTP work closes/abandons that client operation; **remote
GPU inference or SPARQL jobs stop only if the upstream supports disconnect
cancellation**. Configure and verify upstream deadlines/cancellation separately.
This implementation does not claim to forcibly terminate remote processes.
IP rotation can bypass per-IP accounting; global concurrency and per-tool rates
remain shared. There is no global daily monetary budget, CAPTCHA, identity
verification or per-query SPARQL semantic policy in this change.
