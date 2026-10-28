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
| Global daily inference time | 14400 sec | ANONYMOUS_GLOBAL_DAILY_SECONDS |
| Global daily LLM / MCP admissions | 400 / 10000 | ANONYMOUS_LLM_DAILY_CALLS / ANONYMOUS_MCP_DAILY_CALLS |
| Request body / message count / per-message bytes | 1 MiB / 80 / 256 KiB | ANONYMOUS_BODY_BYTES / ANONYMOUS_MESSAGES / ANONYMOUS_MESSAGE_BYTES |
| Request body, caller with its own key | 8 MiB | AUTHENTICATED_BODY_BYTES |
| Abandoned reservation grace | 3600 sec | ANONYMOUS_ABANDONED_GRACE_SECONDS |
| Registered tools / local schemas | 40 / 16 | ANONYMOUS_TOOLS / ANONYMOUS_LOCAL_TOOLS |
| Total local schemas / tool arguments | 64 KiB / 32 KiB | ANONYMOUS_SCHEMA_BYTES / ANONYMOUS_ARGUMENT_BYTES |
| Upstream MCP result bytes | 256 KiB | ANONYMOUS_RESULT_BYTES |
| Ollama context / output tokens | 65536 / 4096 | ANONYMOUS_NUM_CTX / ANONYMOUS_NUM_PREDICT |
| Model slug allowlist | none (any free-access model) | ANONYMOUS_MODELS (comma-separated) |

An admitted ten-round question uses ten LLM requests, not one. The daily call and
daily second budgets bind independently, and which one runs out first depends
on where the model runs: a hosted turn takes seconds, while a locally served
turn can take a minute, so 14400 seconds is roughly 240 local turns or far more
hosted ones. Four exchanges
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
Own-key behaviour is unchanged: a caller paying with its own key is never
throttled. A signed-in caller spending the house credential uses the shared
FreeModelThrottle. Its limits are 30 calls per user per 300 seconds and 120
globally per 300 seconds (`FREE_MODEL_RATE_LIMIT`,
`FREE_MODEL_RATE_WINDOW_SECONDS`, `FREE_MODEL_GLOBAL_RATE_LIMIT`). The 30
preserves what the previous per-worker count of 15 effectively allowed with two
workers.

Origin is never the quota identity. Storage failures reject new work; there is
no cache fallback.

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

## What these limits bound, and what they do not

They bound CALLS, TIME and INPUT SIZE. They do not bound money directly, and
there is no provider-aware monetary budget yet.

The daily call ceiling is the closest thing to a cost ceiling, and it is an
estimate, not a guarantee. The arithmetic behind the figure quoted on PR #192:

- A PubDictionaries conversation cost about $0.005 when measured on 2026-10-14.
  That measurement assumed gpt-oss-120b on Bedrock and a fixed floor of about
  2,900 tokens per turn.
- A conversation of that kind uses about three LLM calls.
- At 400 calls a day, that is roughly 130 conversations, or about $20 to $25 a
  month.

Those assumptions are what make the number small. A conversation carrying large
tool results costs more per call, because cost follows tokens rather than calls.
The input bounds are therefore part of the cost control, not separate from it:
`ANONYMOUS_MESSAGE_BYTES`, `ANONYMOUS_BODY_BYTES` and `ANONYMOUS_RESULT_BYTES`
cap how large a single call can become. Treat the monthly figure as an order of
magnitude for one deployment's traffic, and keep the provider-side budget alert
as the control that does not depend on an estimate.

## Errors and uncertain upstream work

Pre-SSE: invalid input 400, body too large 413, IP rate/slots/budget 429,
global slots/daily budgets/disabled/unavailable admission 503. Retryable admission
rejections include Retry-After, exposed by CORS. No provider work starts after
rejection. Once SSE starts, emit `error` and close without successful `done`.
MCP deadline returns 504; oversized upstream response is a bounded 502 failure.
Clients must show errors and stop orchestration, not automatically retry.

The monitor interrupts the local operation and closes its HTTP socket on timeout,
disconnect or stop. **A socket close does not prove the upstream GPU or tool stopped.** A
reservation cancelled that way is quarantined. So is the expired reservation of
a crashed worker. The alternative would admit replacement GPU work on the
strength of an expired timer. No promise of remote job termination is made:
configure provider-side limits and monitor Ollama separately.

**The rule is whether the outcome arrived, not whether the call failed.** A
provider error, a malformed response or a bug in our own code arrived as a
result. The call is over, so the slot is released and the elapsed time charged.
Quarantining those as well meant two provider errors could occupy both global
LLM slots and answer every anonymous visitor with 503 until an operator
intervened. The state is in Postgres, so restarting the server did not clear it.

A transport failure is the opposite case and is quarantined:

| failure | upstream state | slot |
|---|---|---|
| HTTP 4xx or 5xx response | the provider answered | released |
| Read or write timeout | may still be generating | quarantined |
| Connection lost mid-answer (`ECONNRESET`, `EPIPE`, `EOFError`) | may still be generating | quarantined |
| Deadline, client disconnect, operator stop | may still be generating | quarantined |
| Connect timeout, DNS failure, connection refused | never started | released |

`McpClient` reports a post-write timeout as `McpUpstreamTimeoutError`, which
carries the `UpstreamUncertain` marker, so a wrapped transport failure takes the
quarantine path as well. A connect timeout is a `Timeout::Error` too, but it
happens before the request is written, so it releases the slot.

**The grace release is recovery WITHOUT confirmation that upstream stopped.**
A quarantined reservation releases itself once it is
`ANONYMOUS_ABANDONED_GRACE_SECONDS` past its deadline. The default is 3600. The whole reservation is charged and a warning is logged with the
reservation id, kind, subject and charged seconds. This is an availability
trade-off, not a verification: nothing has established that the GPU or the
remote tool finished. Set the variable higher, or to a very large value, if your
deployment prefers to wait for an operator instead.

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
