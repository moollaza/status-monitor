---
date: 2026-04-11
updated: 2026-04-18
topic: statusmonitor-backend-service
---

# StatusMonitor Backend Service

## Problem Frame

StatusMonitor's v1 architecture has each Mac app client independently polling every status page it monitors. At scale, this is wasteful — but v1 isn't at scale yet. The backend was originally framed as the next thing to build; after exploration and a competitive/demand analysis, the plan has changed:

**Backend is parked until Pro demand is validated.** v1 works for individual users. The backend solves scale + dynamic catalog + multi-client reach, all of which are only valuable if there's meaningful adoption. The near-term focus is lower-cost work that either validates demand or fills user-visible gaps in v1.

This document preserves the full v2.0 backend architecture as a parked design — ready to execute when/if the trigger fires — while putting the near-term workstreams up front.

## Market Context (2026-04-18)

Competitive research surfaced a narrow but validated category:

- **StatusGator** (~$250K ARR after 7 years, indie bootstrap) and **IsDown** (~$27-45/mo SaaS) lead. Both are cloud web apps requiring accounts.
- **No native desktop app** exists in the SaaS-aggregator category.
- **No genuinely privacy-preserving / local-first option** exists.
- **IsDown shipped an MCP server in Jan 2026, gated to Enterprise.** A free/open MCP built on an open catalog is a vacant position.
- Category ceiling is indie-scale. This is not a venture-scale market.

**Project purpose:** an open, privacy-preserving, Mac-native tool for people who want to know when their SaaS vendors break, without trusting a cloud aggregator with their vendor list. Monetization is an open question — if Pro demand validates, the project scales; if not, the project stays free forever and backend work stops.

## Near-Term Plan (pre-backend)

Four parallel workstreams. All cheap. All designed to either validate demand or fill real user-visible gaps in v1 without taking on backend infrastructure yet.

### 1. Pro Demand Validation (marketing test)

- N1. Add a "Pro waitlist" signup form to the website. Capture email + short "what would make you pay?" free-text.
- N2. Do light marketing: HN Show HN, Product Hunt launch, relevant subreddits, macOS app roundups. Target signup volume to decide:
  - <50 signups in 3 months → project stays free/OSS. Close the backend brainstorm.
  - 50-200 → evaluate Pro shape based on waitlist responses.
  - 200+ → clear signal; backend + Pro tier become the next bet.
- N3. Keep the waitlist copy intentionally vague about what Pro includes — this is a demand probe, not a pricing test.

### 2. Minimal MCP Server (real-usage signal)

- N4. Build a minimal MCP server exposing the current 1,686-service catalog. Tools: `get_status(service)`, `list_incidents(service)`, `search_services(query)`. No backend required — MCP can read the same per-service endpoints the Mac app hits.
- N5. Publish to the public MCP directory. Instrument anonymous tool-call counts via a simple metrics endpoint.
- N6. 60-day evaluation:
  - <10 weekly active installs → kill it, MCP is not an audience worth serving here.
  - 10-100 → keep maintaining, consider promoting.
  - 100+ → MCP is a real channel; invest more (better tools, caching layer, maybe eventually a hosted version).
- N7. Ship as OSS, BSD/MIT/Apache. No registration, no API keys.

### 3. Top-10 Custom Status Page Parsers

Closes the most visible catalog gap. Users in enterprise settings will notice the absence of these before they notice the absence of anything else.

- N8. Build bespoke parsers for the top 10 non-Atlassian/incident.io status pages: **Slack, Google Workspace (Gmail/Drive/Docs), Okta, Salesforce, Heroku, PayPal, Firebase, Fastly, Microsoft 365, Docker Hub**.
- N9. Each parser gets:
  - A minimal HTML/JSON extraction of current status + incident list
  - A snapshot test against a known-good fixture
  - An alert (GitHub issue auto-filed) when the parse fails, so breakages are caught fast
- N10. Budget: ~1 day per parser initial build, ~2 days/year maintenance per vendor when formats change. Total: ~3 weeks upfront, ~1 week/year ongoing.
- N11. Update CLAUDE.md to reflect that custom parsers are *selectively* in scope (top ~10 only, not arbitrary custom pages).

### 4. CT Log Catalog Discovery

- N12. Implement the CT-log-mining pipeline: query `crt.sh` JSON API for `%.statuspage.io` and walk Atlassian shared-SAN certs to extract customer domains. Probe `/api/v2/summary.json` on each. Merge via existing `scripts/discover-services.py`.
- N13. Target: grow verified catalog from ~1,686 to **5,000+** services. Prior discovery already merged MIT-licensed sources; CT logs are the genuinely new yield.
- N14. Weekly cron to catch newly-onboarded Atlassian customers.
- N15. Known discovery-gap services (Docker Hub, PagerDuty, Mailchimp, Databricks, Hugging Face, Mistral, Perplexity, Pipedrive, Replit, Deel, etc.) should flow in via this pipeline.

---

## Parked: v2.0 Backend Architecture

Everything below is the full design for v2.0 when it ships. It's preserved so that if the Pro demand signal (or any other trigger) fires, the architecture is ready to execute without re-brainstorming.

**Trigger to un-park:** 200+ Pro waitlist signups, OR meaningful adoption signal from v1 (e.g. app hits >10k DAU), OR MCP usage exceeds what direct per-service polling can support.

### How It Would Work

```
Cloudflare Workers (cron, every 60s for high-priority services)
  └─ Parallel fetch /api/v2/summary.json endpoints
  └─ Compute packed status bitmap + per-service incident metadata
  └─ Write snapshot.bin + snapshot.json to R2 when content hash changes

Cloudflare Workers (serves /v1/snapshot.bin, /v1/catalog.json)
  └─ Reads from R2, returns with Cache-Control: max-age=30
  └─ Cloudflare CDN absorbs the majority of client reads

Clients (Mac app, iOS, web, agents via MCP)
  └─ GET https://statusmonitor.app/v1/snapshot.bin (conditional GET w/ ETag)
  └─ Decode bitmap against locally-bundled catalog
  └─ Diff vs last state; notify user's monitored services only
  └─ Fallback to direct per-service polling if backend unreachable
```

Latency target: ≤60-90s from provider status change to client notification.

### Requirements

**Ingestion:**
- B1. Tiered ingestion (JSON API → RSS → email subscriptions) — see Ingestion Tiers below.
- B2. Cloudflare Workers cron triggers. Priority-tiered polling (see Polling Cadence) to stay within free-tier subrequest limits.
- B3. Write packed snapshot to R2 only on content-hash change (dedups no-op polls).
- B4. Target ≤60-90s end-to-end latency.

**Delivery:**
- B5. Serve `/v1/snapshot.bin` (packed) and `/v1/snapshot.json` (debuggable fallback) via Workers reading R2, `Cache-Control: max-age=30`.
- B6. Serve via Workers (not direct R2 bucket) so CF CDN absorbs reads and R2 read quota is preserved.
- B7. Publish `/v1/catalog.json` so clients update service list without app release.
- B8. No accounts, no authentication, no per-user state.

**Wire Format:**
- B9. Ship static catalog (IDs, names, URLs, categories) bundled in app. Backend transmits only *dynamic* state.
- B10. Packed bitmap (~2 bits/service × 1,683 ≈ 421 bytes) + compact incident list. Typical payload ~400-800 bytes. JSON fallback also published.
- B11. HTTP conditional GET (ETag) for 304s on unchanged polls (~200 bytes of headers only).

**Ingestion Tiers (implement in order):**
- B12. **Tier 1 — JSON API polling.** Atlassian Statuspage + incident.io. `/api/v2/summary.json` with conditional GET. ~70% of catalog. Ship in v2.0.
- B13. **Tier 2 — RSS/Atom feed polling.** For services without JSON API. Ship in v2.0.
- B14. **Tier 3 — Email subscriptions (push).** For top 20-30 high-value services. Via Cloudflare Email Workers in v2.1+ only when sub-30s detection is worth the complexity.
- B15. No webhook subscriptions from providers — Atlassian/incident.io webhooks are owner-only.

**Polling Cadence (priority-tiered):**
- B15a. Top ~100 services: every **60s**.
- B15b. Next ~500: every **5 min**.
- B15c. Long-tail: every **15 min**.
- B15d. Priority list is hand-curated using public signals (Tranco rank, GitHub stars on SDK repos, npm download counts, G2 review counts, HackerNews mention frequency). Start with hand-picked top 100, refine later.
- B15e. If subrequest limits become painful, upgrade to $5/mo Workers paid plan rather than engineer around it.

**Mac App Integration:**
- B16. App fetches backend snapshot by default: one GET per poll interval.
- B17. Fallback to direct per-service polling on backend unreachable (network error, timeout, 429). User-invisible.
- B18. User-added custom URLs never touch the backend — polled client-side.
- B19. Backend base URL configurable (for self-hosting), defaults to StatusMonitor-hosted service.

**Catalog:**
- B20. Start v2.0 with whatever catalog size has been achieved by workstream N12-N15.
- B21. Accept community PR contributions — open-source data.
- B22. CT log mining pipeline runs weekly (continues the work started in N12).
- B23. Repo already has prior discovery data under `scripts/` — current catalog is the verified merge.
- B24. Do not scrape commercial aggregators (StatusGator, IsDown) — ToS risk.

**Known Catalog Gaps (as of 2026-04-18 audit):**
- B25. **Discovery gap** — likely on Atlassian/incident.io but not yet in catalog: Docker Hub, PagerDuty, Mailchimp, Databricks, Hugging Face, Mistral, Perplexity, Pipedrive, Replit, Deel. Addressed by N12-N15 (CT log mining).
- B26. **Coverage gap** — services using custom (non-Atlassian) status pages: Slack, Heroku, Firebase, Google Workspace, Okta, Salesforce, PayPal, Fastly, Microsoft 365. Addressed by N8-N11 (top-10 custom parsers).

## Success Criteria

**Near-term (next 1-3 months):**
- Pro waitlist + marketing produces a clear demand signal (above or below the 50/200 thresholds in N2).
- Top 10 custom parsers ship, closing the most-visible catalog gap.
- CT log discovery grows catalog toward 5,000+ services.
- MCP server live, with 60 days of anonymous usage data to evaluate.

**If/when backend ships (v2.0):**
- A user monitoring 20 catalog services makes 1 HTTP request (~500 bytes) per poll interval instead of 20.
- Status changes reach clients within ≤60-90s worst-case.
- Infra cost: $0 up to ~1k DAU, ~$5-20/mo at ~10k DAU.
- Mac app works identically with or without the backend.
- No per-user data collected.

## Scope Boundaries

- No user accounts, authentication, or per-user subscriptions in v2.0. Ever, if the project stays free.
- No per-user push notifications; broadcast snapshot is sufficient.
- No SSE, WebSockets, or persistent connections in v2.0.
- Custom status pages: **selectively in scope** — top ~10 only (N8). Arbitrary custom pages remain out of scope.
- No telemetry or analytics in the backend.
- Pro tier shape is a separate product question; the architecture is Pro-neutral.
- Self-hosting is natural (public data + open repo) but not a first-class feature.

## Key Decisions

- **Backend is parked until Pro demand is validated.** v1 is live and works for individuals. Building backend before demand is speculative; the cheaper path is to test demand first.
- **Cloudflare Workers + R2 when we do build it.** Rejected GitHub Actions + jsDelivr because GitHub Actions cron minimum is 5 min (often delayed to 10-15+) which is too slow for a status monitor. CF Workers 1-min cron is reliable on the free tier.
- **Latency target ≤60-90s.** Slower than that erodes the product's reason to exist.
- **Priority-tiered polling** to fit free-tier subrequest limits. If it gets painful, pay $5/mo rather than engineer around it.
- **Broadcast, not per-user.** Server returns all statuses; client filters locally. Maximally private, cheapest to serve.
- **Static catalog in app, dynamic status in packed bitmap.** ~400 bytes typical payload (60× smaller than naive JSON).
- **Future push layer stays additive.** Silent APNs/Web Push wake-signals — no Durable Objects, no per-user subscription knowledge.
- **Pro is not the business model assumption.** If Pro validates, backend ships; if not, project stays free and backend brainstorm closes.
- **Custom parsers: selectively in scope.** Top 10 only, with snapshot tests + failure alerts. Accept ~2 days/year/vendor maintenance cost.
- **MCP: demand-tested, not assumed.** Ship minimal MCP, measure real usage over 60 days, invest based on signal.

## Dependencies / Assumptions

- Cloudflare Workers free tier (100k req/day) is sufficient for launch and early growth.
- R2 free tier (10M reads/mo, 1M writes/mo) is sufficient with CF CDN absorbing reads.
- `/v1/snapshot.bin` payload stays under ~2KB even during major outages.
- Status providers don't rate-limit CF Workers egress at the tiered cadence.
- MCP directory discovery is functional and agents do find/use listed servers.
- CT log data from `crt.sh` remains accessible without paid API tier.

## Future Layers (with explicit triggers)

Documented, not built until the trigger fires:

| Layer | Trigger to build |
|---|---|
| v2.0 Backend (CF Workers + R2) | 200+ Pro waitlist signups, OR >10k v1 DAU, OR MCP usage outgrows direct polling |
| Silent APNs push for sub-10s latency | Users complain about latency after v2.0 ships |
| Cloudflare Email Workers (Tier 3 ingestion) | Sub-30s detection desired for top services |
| Expanded MCP (caching, more tools, hosted version) | MCP usage >100 weekly active installs |
| Public web dashboard + Web Push | Specific demand, or SEO investment decision |
| iOS app | Mac app has real traction AND capacity for two clients |
| Email/SMS/Slack alerts + accounts | Paid pilot validates willingness to pay |
| Dep-graph health oracle for agents | MCP usage data validates a paid agent tier |

## Explicit Non-Goals

- PIR, Tor / mix networks, cover traffic — wrong threat model for public data.
- Durable Objects, SSE, WebSockets, long-polling — broadcast snapshot + optional APNs doorbell serves every push need.
- Per-user subscription state on the server — undermines privacy, unnecessary.
- Bloom-filter subscription hints — larger than the packed snapshot at our scale.
- DNS TXT, IPFS, Nostr, ActivityPub transports — each has a fatal flaw (TTL, propagation, SLA).
- Scraping commercial aggregators (StatusGator, IsDown) — ToS risk.
- Covering *all* custom status pages — only the top ~10.

## Outstanding Questions

### Resolve Before Planning
- None — the near-term plan (N1-N15) is concrete enough to proceed.

### Deferred to Planning (for each workstream's /ce:plan)
- [Affects N1-N3] Exact Pro waitlist copy and signup targets. Which marketing channels, in what order.
- [Affects N4-N7] MCP server language/framework (TypeScript via MCP SDK is the default). Metrics endpoint schema.
- [Affects N8-N11] Order to tackle custom parsers in. Snapshot test harness design. CLAUDE.md update wording.
- [Affects N12-N15] CT log query strategy — pagination, rate limits on `crt.sh`. Verification batch size. Integration with existing `discover-services.py`.
- [Affects B15a-c] Exact priority-tier list (top 100 services).
- [Affects B2] Free-tier subrequest workaround vs. $5/mo Workers.
- [Affects B10] Exact packed bitmap schema and versioning.
- [Affects B5] Cache-Control / ETag TTL tradeoff.
- [Affects B12-B13] Parser reimplementation (Swift → JS/TS/WASM for Workers).
- [Affects B17] Mac-app fallback timeout/retry semantics.

## Cost Model

**Near-term workstreams:** $0 infra cost.

| Workstream | Cost |
|---|---|
| Pro waitlist + marketing | $0 (Formspree / Plausible free tier) |
| MCP server | $0 (OSS, runs client-side) |
| Custom parsers | $0 (ships inside Mac app) |
| CT log discovery | $0 (`crt.sh` free) |

**If/when v2.0 backend ships:**

| Scale | Daily active users | Infra cost |
|---|---|---|
| Launch | <100 | **$0** |
| Growth | 1,000 | **$0** |
| Scale | 10,000 | **$0-5/mo** |
| Large | 100,000 | **~$5-20/mo** |
| Huge | 1M+ | **~$50-100/mo** |

## Roadmap

- **v1 (current):** Mac app, direct client-side polling, bundled catalog (~1,686 services).
- **v1.x (near-term):** Pro waitlist + marketing (N1-N3), MCP server (N4-N7), top-10 custom parsers (N8-N11), CT log discovery (N12-N15). All four in parallel.
- **v2.0 (parked, trigger: Pro demand signal):** CF Workers + R2 backend with priority-tiered polling, packed bitmap delivery, Mac app backend-first with direct-polling fallback.
- **v2.x (opt-in, triggers listed in Future Layers table):** Tier 3 email ingestion, silent APNs push, expanded MCP.
- **v3 (speculative, demand-gated):** Identity-required features (email alerts, teams, web dashboard).

## Next Steps

→ `/ce:plan` on **workstream N8-N11 (top-10 custom parsers)** — most user-visible impact, ships inside v1 Mac app, no new infra.
→ `/ce:plan` on **workstream N4-N7 (MCP server)** — cheap demand test for the agent audience.
→ `/ce:plan` on **workstream N12-N15 (CT log discovery)** — 3-4 days of work, bumps catalog to 5k+.
→ Pro waitlist (N1-N3) is simpler — can be implemented directly without a full plan.
→ Backend v2.0 plan stays dormant until trigger fires.
