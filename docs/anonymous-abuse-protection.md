# Shared abuse protection for anonymous static widgets

Static HTML still calls the hub directly. CORS remains a browser response-access
policy; it is not authentication. Every anonymous inference/MCP execution is
admitted independently on the server, including requests made without a browser.
The widget's `max-exchanges=4` and `max-rounds=10` do not enforce server quotas.

## Identity and shared admission

PostgreSQL row locking shares rate counters, execution reservations, daily
budgets and emergency switches across all workers/instances using the same DB.
Admission and settlement hold the lock briefly; inference never holds it.
Anonymous quotas use an HMAC of the network client IP with the Rails secret,
not Origin, Referer, User-Agent, DNS names or client-provided session IDs.
Changing/omitting Origin does not create a new budget. Users sharing NAT share
an IP budget. Raw IPs, prompts and credentials are not stored in admission state.

`AdmissionClientIp` accepts Rails' forwarded IP chain only when the TCP peer
(`REMOTE_ADDR`) belongs to an explicitly configured trusted ingress. Otherwise
it uses the TCP peer, regardless of X-Forwarded-For. When
`ANONYMOUS_TRUSTED_PROXIES` is unset, production trusts loopback only and logs
that it did so. An empty trust list is worse than it looks. Every visitor
behind a local nginx is then accounted for as 127.0.0.1, so the whole internet
shares one quota bucket. The symptom reads as a bug, not as a missing
variable. At ingress,
overwrite incoming forwarding headers; keep Rails and Ollama off the public
network so there is no bypass. All workers must share the Rails secret and DB.

## Defaults (tune to measured capacity)

| Limit | Default | Environment variable |
| --- | --- | --- |
| LLM calls per IP / rolling minute | 30 | ANONYMOUS_LLM_RATE |
| MCP calls per IP / rolling minute | 60 | ANONYMOUS_MCP_RATE |
| LLM slots per IP / globally | 1 / 4 | ANONYMOUS_LLM_PER_IP / ANONYMOUS_LLM_GLOBAL |
| MCP slots per IP / globally | 2 / 8 | ANONYMOUS_MCP_PER_IP / ANONYMOUS_MCP_GLOBAL |
| LLM / MCP request deadline | 600 / 30 sec | ANONYMOUS_LLM_SECONDS / ANONYMOUS_MCP_SECONDS |
| Per-IP daily inference time | 1800 sec | ANONYMOUS_DAILY_SECONDS |
| Global daily inference time | 7200 sec | ANONYMOUS_GLOBAL_DAILY_SECONDS |
| Global daily LLM / MCP admissions | 400 / 10000 | ANONYMOUS_LLM_DAILY_CALLS / ANONYMOUS_MCP_DAILY_CALLS |
| Request body / message count / per-message bytes | 1 MiB / 80 / 256 KiB | ANONYMOUS_BODY_BYTES / ANONYMOUS_MESSAGES / ANONYMOUS_MESSAGE_BYTES |
| Request body, caller with its own key | 8 MiB | AUTHENTICATED_BODY_BYTES |
| Abandoned reservation grace | 3600 sec | ANONYMOUS_ABANDONED_GRACE_SECONDS |
| Registered tools / local schemas | 40 / 16 | ANONYMOUS_TOOLS / ANONYMOUS_LOCAL_TOOLS |
| Total local schemas / tool arguments | 64 KiB / 32 KiB | ANONYMOUS_SCHEMA_BYTES / ANONYMOUS_ARGUMENT_BYTES |
| Upstream MCP result bytes | 256 KiB | ANONYMOUS_RESULT_BYTES |
| Ollama context / output tokens | 65536 / 4096 | ANONYMOUS_NUM_CTX / ANONYMOUS_NUM_PREDICT |
| Model slug allowlist | none (any free-access model) | ANONYMOUS_MODELS (comma-separated) |

An admitted ten-round question uses ten LLM requests, not one. Four exchanges
can therefore use up to forty LLM calls plus tools. Verify realistic guide,
schema and tool-result sizes against body/context limits before deployment.
The guide (~117 KB) fits the per-message limit. Model installation and catalog
availability are deployment prerequisites; set the allowlist explicitly.

Anonymous inference is restricted to models that need no caller API key —
`LlmModelMap.free_access_model?`, which is every Ollama model plus any model an
administrator has flagged `free_access`. That includes house-paid hosted models
such as gpt-oss-120b on Bedrock, which is what pubdictionaries.org and
togomcp.rdfportal.org serve anonymously today. `ANONYMOUS_MODELS` narrows the
set further when set, and is empty by default.

Daily seconds are not a monetary budget, and that gap is real: these limits
bound CALLS and TIME, not spend. Until provider-aware monetary accounting
exists, the money controls are the daily call ceilings in the table above and
the AWS budget alert.
Signed-in own-key behavior is retained; signed-in callers spending the house
credential use the shared FreeModelThrottle (15 calls/user per 300 seconds,
120 globally per 300 seconds; FREE_MODEL_RATE_LIMIT,
FREE_MODEL_RATE_WINDOW_SECONDS, FREE_MODEL_GLOBAL_RATE_LIMIT). Origin is never
the quota identity. Storage failures reject new work; there is no cache fallback.

Daily budgets use UTC admission days. Time is atomically reserved before an
LLM call; successful calls settle elapsed time (capped at the reservation).
A cancelled or abandoned reservation is retained (see below); a failure that
arrived as a result settles like a success, charging the elapsed time. Global admission
counts remain consumed on failures, preventing distributed retries from
bypassing the daily count. Metadata state has bounded tracked-client retention.

Generation settings accept only options, think, temperature and top_p; Ollama
options accept num_ctx, num_predict, temperature, top_p, repeat_penalty and seed.
Catalog context/output defaults are capped to anonymous limits before merging
caller overrides. Explicit excessive/unbounded settings and unknown options are
rejected, rather than passed to the provider.

Per-tool global defaults: concurrency 2, MCP_RATE calls/minute, MCP_SECONDS and
RESULT_BYTES. Overrides by original tool name are capped by server-wide limits:

```sh
ANONYMOUS_TOOL_LIMITS='{"TogoMCP_Usage_Guide":{"concurrency":1,"rate":10,"seconds":20,"result_bytes":262144}}'
```

## Protected paths and compatibility changes

- Anonymous single_llm_calls and direct `/api/mcp_tools/:id/call` require admission.
- Anonymous `/chats` and `/chat_streams` return 403; use single_llm_calls.
  This closes a legacy inference/tool-loop bypass. Authenticated calls remain.
- Anonymous MCP discovery reads cached DB schemas and never triggers a remote
  refresh. Operators/authenticated refreshes populate that cache.
- A supplied malformed/invalid Authorization header is rejected; it cannot
  downgrade into anonymous access. Existing authenticated API calls still verify
  Google tokens. Missing authentication on auth-required API paths retains its
  existing response.
- Inference/MCP body limits apply before JSON parsing, including absent
  Content-Length, and also protect authenticated requests on these paths.
- Active/public_to_anonymous tool and server visibility remains mandatory.

## Errors and uncertain upstream work

Pre-SSE: invalid input 400, body too large 413, IP rate/slots/budget 429,
global slots/daily budgets/disabled/unavailable admission 503. Retryable admission
rejections include Retry-After, exposed by CORS. No provider work starts after
rejection. Once SSE starts, emit `error` and close without successful `done`.
MCP deadline returns 504; oversized upstream response is a bounded 502 failure.
Clients must show errors and stop orchestration, not automatically retry.

The monitor interrupts the local operation and closes its HTTP socket on timeout,
disconnect or stop. **A socket close does not prove the upstream GPU/tool stopped.**
A reservation cancelled that way is therefore quarantined, as is the expired
reservation of a crashed worker, rather than admitting replacement GPU work on
the strength of an expired timer. No promise of remote job termination is made:
configure provider-side limits and monitor Ollama separately.

An ordinary failure is treated differently. A provider error, a malformed
response or a bug in our own code ARRIVED as a result, so the call is over: the
slot is released and the elapsed time charged. Quarantining those as well meant
two provider errors could occupy both global LLM slots and answer every
anonymous visitor with 503 until an operator intervened — and because the state
is in Postgres, restarting the server did not clear it.

A quarantined reservation is also released automatically once
`ANONYMOUS_ABANDONED_GRACE_SECONDS` (default one hour) has passed beyond its
deadline, charging the whole reservation, with a warning logged. An operator who
never reads the log must not be the reason a public page stops answering.

After verifying the upstream job has stopped, use the operator-only command:

```sh
bundle exec rails anonymous_usage:reconcile ID=reservation-uuid CONFIRMED_STOPPED=true ACTOR=operator REASON=verified-provider-stopped
```

Only uncertain/expired reservations are eligible. Recovery charges full reserved
time and records actor/reason; it cannot be repeated for the same reservation.
Use it to release a slot sooner than the grace period, not as the only route.
Successful normal requests release immediately. There is no public recovery API.

## Deployment

```sh
bundle exec rails db:migrate
# Configure limits, models and actual ingress CIDRs; restart all Puma workers.
# ANONYMOUS_TRUSTED_PROXIES=127.0.0.1/32,::1/128
```

Do not leave old unprotected workers running during a mixed-version rollout;
pause anonymous traffic until all workers have the migration and matching config.
Provide DB pool headroom for controller/live and monitor connections. The shared
singleton row suits small public widgets; load-test before raising concurrency.
At ingress enforce body/header/read timeouts and coarse connection/rate limits,
so floods are rejected before occupying Rails/DB resources. Application policy
cannot prevent network bandwidth exhaustion or slow body uploads by itself.

```nginx
# http context
limit_req_zone $binary_remote_addr zone=widget_ingress:10m rate=2r/s;
# server context
location /api/ {
    client_max_body_size 1m;
    client_body_timeout 10s;
    limit_req zone=widget_ingress burst=10 nodelay;
    limit_req_status 429;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_read_timeout 620s;
    proxy_pass http://127.0.0.1:3000;
}
```

Operators can independently stop/resume anonymous LLM and MCP admission:

```sh
bundle exec rails anonymous_usage:set KIND=llm ENABLED=false ACTOR=operator REASON=incident
bundle exec rails anonymous_usage:set KIND=mcp ENABLED=false ACTOR=operator REASON=incident
bundle exec rails anonymous_usage:set KIND=llm ENABLED=true ACTOR=operator REASON=recovered
```

Running work observes shared stop state every 250ms subject to DB availability.
Startup ANONYMOUS_LLM_ENABLED=false / ANONYMOUS_MCP_ENABLED=false overrides a
shared resume. Audit events log hashed subjects and operator changes without
prompts or credentials. Forward logs to persistent audit storage.
