---
title: "feat: RSS-first coverage for top non-Atlassian status pages"
type: feat
status: active
date: 2026-04-18
deepened: 2026-04-18
origin: docs/brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md
---

# feat: RSS-first coverage for top non-Atlassian status pages

## Overview

Close the catalog's coverage gap for top non-Atlassian / non-incident.io status pages (Slack, Google Workspace, Okta, Salesforce, Heroku, PayPal, Firebase, Microsoft 365) by adding them as **RSS-typed catalog entries**, reusing the existing `RSSParser` + `rssStatusHeuristic` infrastructure. Only fall back to custom parsers for services that have no RSS feed AND are valuable enough to warrant bespoke code — likely zero to one service.

**Why the plan changed:** an earlier draft proposed ~10 custom parsers with a new `ProviderType.custom` case, per-vendor Codable types, a registry pattern, and weekly drift-detection CI. Review + user pushback surfaced that most of these vendors publish RSS/Atom feeds at their status pages, and the app already has a working RSS pipeline (the same one that handles AWS, GCP, and other non-Atlassian services). RSS-first is simpler, lower-maintenance, and covers the same user-visible gap.

## Problem Frame

Per the origin document's catalog audit (B26): a status monitor missing Slack, Google Workspace, Okta, Salesforce, and similar feels incomplete in enterprise contexts. The current project stance ("custom proprietary status pages are out of scope" per CLAUDE.md) blocks this coverage.

We can close most of the gap without writing any new parser code. Status pages — even non-Atlassian ones — almost universally publish RSS/Atom feeds for their incident history. The existing `RSSStatusParser` in `Services/RSSParser.swift` and the keyword heuristic in `StatusManager.rssStatusHeuristic` already handle generic RSS from vendors like AWS, GCP, and Pinterest. Adding new services typed as `.rss` costs nothing but a catalog entry and a fixture test confirming the heuristic classifies their phrasing correctly.

## Requirements Trace

- R1. Add coverage for the top ~8 non-Atlassian / non-incident.io status pages from the origin list (N8 in origin) using RSS/Atom feeds where available.
- R2. Each new RSS-typed entry has a fixture-backed test proving `rssStatusHeuristic` correctly classifies that vendor's incident titles and descriptions (N9 in origin, lightweight form — no weekly CI drift alerts needed since heuristic changes don't drift silently like vendor JSON formats).
- R3. For vendors without an RSS feed, the decision defaults to **dropping them from scope**. Custom parsers are a last-resort fallback, only built if a vendor is both gap-critical and has no RSS, and even then limited to at most one or two.
- R4. Update CLAUDE.md to replace "Custom proprietary status pages are out of scope" with a stance that reflects RSS-first coverage (N11 in origin).
- R5. Total maintenance budget: heuristic-tuning as needed when vendors adopt new phrasing. No per-vendor parser code to maintain.

## Scope Boundaries

- **Out of scope:** Custom parser infrastructure (`ProviderType.custom`, registry, protocol) — not needed. Revisit only if a gap-critical vendor has no RSS.
- **Out of scope:** Weekly drift-detection CI. The RSS-heuristic path doesn't drift silently like vendor JSON parsers would — if a vendor changes incident phrasing, the worst case is `.unknown` status, not misclassification.
- **Out of scope:** HTML scraping of vendor status pages (Okta's React shell, Microsoft 365 portal, etc.). If RSS isn't available, drop the service.
- **Out of scope:** Atlassian-hosted vendors that were wrongly listed in the original B26 gap (Fastly, Docker Hub). Plan #001's CT discovery picks these up — confirmed by Unit 0 in that plan.
- **Out of scope:** User-facing UI changes.
- **Out of scope:** Handling vendors that gate status behind auth (Microsoft 365 portal). Public feed only.

## Context & Research

### Relevant Code and Patterns

- `Services/RSSParser.swift` — `RSSStatusParser` class, XMLParser-based, handles both RSS 2.0 and Atom. Returns `[RSSItem]`. Already production.
- `Services/StatusManager.swift: rssStatusHeuristic(title:description:)` at lines 483-527 — classifies RSS items into `ComponentStatus` via keyword matching. Already handles: "resolved/completed/closed" → operational; "major/outage/critical" → majorOutage; AWS-style "Service impact:" / "Service disruption:" / "Service issue:" → partialOutage; "partial" → partialOutage; "degraded/elevated/increased error/investigating/identified/experiencing" → degradedPerformance; "operational" → operational. This is exactly the extension point new vendors plug into.
- `Services/StatusManager.swift: parseRSS(data:provider:)` at lines 529-562 — full pipeline from bytes to `ProviderSnapshot`, using `rssStatusHeuristic` for the overall status and per-item classification.
- `Models/Models.swift: ProviderType.rss` — existing enum case. No new case needed.
- `Models/Models.swift: Provider.apiURL` — for `.rss`, returns `baseURL` as-is. Compatible with vendor RSS feed URLs (e.g. `https://status.slack.com/feed/rss`).
- `Resources/catalog.json` — entries like `{"type": "rss", ...}` already exist in the catalog (verified for AWS, GCP, etc.). New entries drop in at the same shape.
- `StatusMonitorTests/RSSParserTests.swift` — inline-string fixture pattern.
- `StatusMonitorTests/CloudProviderRSSTests.swift` — precedent for per-vendor tests that exercise `rssStatusHeuristic` against realistic titles.
- `CLAUDE.md` — contains the "Custom proprietary status pages are out of scope" line to update.

### Institutional Learnings

No `docs/solutions/` entries — no prior art in this repo for this specific approach, but `CloudProviderRSSTests.swift` demonstrates the pattern this plan extends.

### Expected RSS Endpoints (validated in Unit 1)

| Service | Expected feed URL | Notes |
|---|---|---|
| Slack | `https://status.slack.com/feed/rss` | Public RSS; format stable. |
| Okta | `https://status.okta.com/history.rss` | Standard RSS history feed. |
| Salesforce | Trust site RSS per-instance, or global | May need region-specific handling; global feed first. |
| Heroku | `https://status.heroku.com/feed` | Public RSS. |
| Google Workspace | `https://www.google.com/appsstatus/dashboard/en/feed.atom` | Atom. Existing parser handles `<entry>` tags. |
| PayPal | `https://www.paypal-status.com/feed/rss` or Atlassian-hosted variant | Verify in Unit 1. |
| Firebase | `https://status.firebase.google.com/feed.atom` | Google-hosted, likely Atom. |
| Microsoft 365 | **No reliable public feed** (deprecated). Candidate for drop. | See Unit 4. |

## Key Technical Decisions

- **RSS-first for all vendors.** Default path is: add the vendor as a `.rss`-typed catalog entry with its feed URL, let the existing pipeline handle it. No new Swift code.
- **Custom parsers are a last resort.** Only if a vendor has no RSS AND is gap-critical, and only after the RSS path has been exhausted. Target at most zero-to-one custom parsers from this plan.
- **No new ProviderType case.** Skip the `.custom` enum extension, registry pattern, and dispatch infrastructure entirely. This eliminates ~70% of the original plan's complexity.
- **No weekly drift-detection CI.** RSS heuristic failure mode is `.unknown` on unrecognized phrasing — not silent misclassification. A vendor adopting new phrasing surfaces as "Unknown" status in the app, visible to the user and to the maintainer. This is acceptable.
- **Per-vendor heuristic verification via fixture tests** — not drift detection. Each new RSS vendor gets a `StatusMonitorTests/<Vendor>RSSTests.swift` file with realistic sample titles (operational, investigating, resolved, major outage) asserting the expected `ComponentStatus` output. If `rssStatusHeuristic` needs a new keyword for a vendor, it's extended in Unit 3 and all existing vendor tests re-run (cross-vendor regression coverage).
- **Heuristic extensions must remain cross-vendor-safe.** Adding a keyword for Salesforce's phrasing must not regress AWS or GCP classification. The full suite of `CloudProviderRSSTests` + new per-vendor tests is the guardrail.
- **Update CLAUDE.md scope stance before the first catalog entry lands.** Prevents reviewer confusion during PR review.
- **Feed URLs live in `catalog.json` as `base_url`.** Existing schema supports this — `Provider.apiURL` for `.rss` returns `baseURL` as-is, so the polling pipeline fetches the feed directly.

## Open Questions

### Resolved During Planning

- **Q:** Do we need `ProviderType.custom` at all? **A:** No, not for the identified gap. RSS covers the majority of top non-Atlassian vendors. Custom parsers remain *possible* as a future addition but aren't built here.
- **Q:** How do we detect format drift without weekly CI? **A:** We don't need to. RSS heuristic failure → `.unknown` status in the app. User-visible, not silent. Acceptable for a free, OSS, solo-maintained project.
- **Q:** What about Fastly and Docker Hub from the original 10? **A:** Both are Atlassian per plan #001's feasibility review. Plan #001's CT discovery picks them up. Don't duplicate here.
- **Q:** What about Microsoft 365? **A:** Default to dropping from scope. Microsoft's public feed was deprecated. Service Health Dashboard requires an M365 tenant. Unit 4 confirms and documents the drop.
- **Q:** Can we gate this plan on Pro waitlist signal (per adversarial review)? **A:** The RSS-first plan is cheap enough (~2-3 days of work, near-zero ongoing maintenance) that gating on Pro waitlist would be over-cautious. Ship it as a modest coverage improvement; the original 3-week custom-parser investment is what needed the demand gate.

### Deferred to Implementation

- Exact feed URL per vendor (confirmed live in Unit 1).
- Whether Salesforce needs per-region feeds or the global feed is sufficient.
- PayPal's feed location (possibly Atlassian-hosted, possibly proprietary — Unit 1 probes).
- Whether `rssStatusHeuristic` needs extension for any vendor (discover in Unit 2, extend in Unit 3 if needed).
- Whether to replace the dropped Microsoft 365 slot with a different in-demand non-Atlassian service (revisit after shipping, not now).

## Implementation Units

- [ ] **Unit 1: RSS feed availability audit**

**Goal:** Confirm each candidate vendor's RSS/Atom feed URL, incident-title shape, and basic parseability. Produce a small audit artifact that seeds Unit 2's catalog entries.

**Requirements:** R1, R3

**Dependencies:** Plan #001 Unit 3 completion (so the catalog already reflects newly-discovered Atlassian services like Fastly and Docker Hub, eliminating overlap).

**Files:**
- Create: `docs/research/2026-04-rss-audit.md`

**Approach:**
- For each candidate (Slack, Okta, Salesforce, Heroku, Google Workspace, PayPal, Firebase, Microsoft 365):
  - `curl -sI <expected-feed-url>` — confirms 200 + content-type `application/rss+xml` or `application/atom+xml`.
  - `curl -s <feed-url> | head -100` — sample the incident titles + descriptions for heuristic analysis.
  - Note: vendors that require auth, return HTML, or 404 get marked as "no public feed."
- Record for each vendor: feed URL, feed type (RSS/Atom), sample titles for several states (operational / investigating / resolved / outage if observable), whether the existing `rssStatusHeuristic` keywords map cleanly.
- Unit 1 is fast (~1 hour) and inherently exploratory — its output is evidence, not code.

**Test scenarios:**
- None (research step).

**Verification:**
- Audit doc lists each vendor with feed URL + feed type + representative titles OR "no public feed — dropped from scope."
- Expected yield: 6-8 vendors confirmed; Microsoft 365 flagged for drop; PayPal possibly flagged if feed is unreliable.

---

- [ ] **Unit 2: Add RSS catalog entries + per-vendor heuristic verification tests**

**Goal:** Add the confirmed RSS vendors to `catalog.json` as `type: "rss"` entries. Each gets a per-vendor XCTest file verifying `rssStatusHeuristic` classifies their phrasing correctly.

**Requirements:** R1, R2

**Dependencies:** Unit 1 (audit drives the exact vendor list + feed URLs).

**Files:**
- Modify: `Resources/catalog.json` (add ~6-8 RSS entries)
- Create: `StatusMonitorTests/SlackRSSTests.swift` (and one per confirmed vendor)
- Modify: `scripts/audit-catalog.py` if needed (currently only validates `type == "statuspage"` entries; RSS entries should be skipped cleanly — verify current behavior)

**Approach:**
- Catalog entry shape: `{"id": "slack", "name": "Slack", "base_url": "https://status.slack.com/feed/rss", "type": "rss", "category": "Communication", "platform": null}`.
- `platform: null` for non-Atlassian RSS entries. (Confirm `CatalogEntry` decoder handles null — already does per `decodeIfPresent` pattern.)
- Per-vendor test: ~10 realistic RSS item titles per vendor, captured from Unit 1's audit samples, asserting the expected `ComponentStatus` output from `rssStatusHeuristic`. Mirror `CloudProviderRSSTests.swift` structure.
- `scripts/audit-catalog.py` check: entries with `type != "statuspage"` should be skipped from the statuspage-specific validation. Current behavior may already handle this; fix if not (add explicit skip + log).

**Patterns to follow:**
- `StatusMonitorTests/CloudProviderRSSTests.swift` — per-cloud-vendor heuristic test structure, naming, fixture placement.
- `StatusMonitorTests/RSSParserTests.swift` — inline-string fixture pattern.
- Existing catalog entries for shape.

**Test scenarios (per vendor test file):**
- Happy path — "All systems operational" style title classifies as `.operational`.
- Happy path — "Resolved: <incident>" classifies as `.operational`.
- Happy path — vendor's own phrasing for degraded performance (e.g., Salesforce's "We are experiencing issues with...") classifies as `.degradedPerformance`.
- Happy path — vendor's phrasing for major outage classifies as `.majorOutage`.
- Edge case — ambiguous title without keywords (e.g., "Scheduled notice") classifies as `.unknown`.
- Edge case — title with vendor-unique keyword that the heuristic *doesn't* currently handle: document this as a known gap requiring Unit 3's extension.
- Integration — end-to-end: a `Provider(from: <RSS catalog entry>)` polled by `StatusManager` (with injected session returning a fixture feed) produces a `ProviderSnapshot` with the expected `overallStatus`.

**Verification:**
- `xcodebuild test` passes all existing tests + new vendor tests.
- Catalog size grows by the number of confirmed RSS vendors.
- App launches; new vendors are selectable in Settings and produce live status when added.

---

- [ ] **Unit 3: Heuristic extensions (only if Unit 2 identifies gaps)**

**Goal:** Extend `rssStatusHeuristic` with any vendor-specific keywords identified during Unit 2's per-vendor testing. Ensure changes are cross-vendor-safe.

**Requirements:** R2

**Dependencies:** Unit 2.

**Files:**
- Modify: `Services/StatusManager.swift` (specifically `rssStatusHeuristic` at lines 483-527)
- Modify: Any affected vendor test files (add the now-passing case).

**Approach:**
- If Unit 2 surfaced phrasing that the current heuristic doesn't handle (e.g., Okta-specific verbiage, Salesforce-specific verbiage), add the keyword/phrase to the appropriate branch of `rssStatusHeuristic`.
- Maintain cross-vendor regression coverage: all per-vendor tests + existing `CloudProviderRSSTests` must still pass. A new keyword must not shift an existing vendor's classification.
- If extensions become invasive (more than 3-4 new keywords, or conflicting priorities between vendors), stop and reconsider — this is the signal that per-vendor parsing may be warranted for that one vendor, escalate to Unit 4.

**Patterns to follow:**
- Existing comment structure in `rssStatusHeuristic` (numbered sections 1-6 grouping keywords by semantic meaning).
- Resolved-family precedence — already handles "Resolved: Major outage" correctly. New keywords must preserve this.

**Test scenarios:**
- Regression — all existing heuristic tests (`CloudProviderRSSTests` + `RSSParserTests`) still pass.
- Regression — all per-vendor tests from Unit 2 still pass.
- New — each newly-added keyword has at least one test case proving it produces the intended classification.

**Verification:**
- `xcodebuild test` passes. Full heuristic test suite green.

**Execution note:** May be a no-op if Unit 2's vendor tests all pass against the current heuristic. That's the ideal outcome.

---

- [ ] **Unit 4: Scope decision for vendors with no public RSS**

**Goal:** For any candidate from Unit 1 that has no usable public feed (currently expected: Microsoft 365, possibly PayPal), formally drop from scope OR build a single last-resort custom parser. Default is drop.

**Requirements:** R3

**Dependencies:** Unit 1.

**Files:**
- Modify: `docs/research/2026-04-rss-audit.md` (append drop decisions)
- No code changes if we drop; if we build a custom parser for one holdout, that becomes a separate micro-plan.

**Approach:**
- Microsoft 365: confirm no public RSS. Document why it's dropped. Note in the audit that a future plan could revisit if a data source emerges.
- PayPal: if Unit 1 found it on Atlassian (paypal-status.com is Atlassian-hosted), it gets covered by Plan #001's CT discovery anyway.
- Any other dropped vendor: document why.
- If a dropped vendor is judged gap-critical enough to warrant custom-parser effort, write a separate lightweight plan rather than folding it into this plan. Keep this plan RSS-only.

**Decision default:** drop. Do not expand scope.

**Test scenarios:**
- None (scope decision step).

**Verification:**
- Audit doc is updated with explicit drop rationale for each dropped vendor.
- If any vendor is chosen for custom-parser treatment, a separate plan file is created (not this one).

---

- [ ] **Unit 5: Docs + scope-stance update**

**Goal:** Update CLAUDE.md to reflect the new scope stance (RSS-or-Atlassian-or-incident.io supported; arbitrary HTML scraping remains out of scope). Document the small but non-zero possibility of a future custom-parser exception.

**Requirements:** R4

**Dependencies:** Units 1-4.

**Files:**
- Modify: `CLAUDE.md`
- Optionally modify: top-level README if it mentions supported status-page types.

**Approach:**
- Replace the current CLAUDE.md line "Custom proprietary status pages are out of scope. Most catalog services use Atlassian Statuspage or incident.io (compatible JSON schema). RSS/Atom feeds supported for non-Statuspage services." with something like:
  > Most catalog services use Atlassian Statuspage or incident.io (compatible JSON schema). For non-Atlassian vendors that publish RSS/Atom feeds (Slack, Okta, Salesforce, Heroku, Google Workspace, Firebase, etc.), entries are typed as `.rss` and handled by the generic RSS parser plus keyword heuristic. Pure-HTML or auth-gated status pages without a feed remain out of scope; exceptions can be made case-by-case with a dedicated custom parser but should be rare.
- Keep CLAUDE.md concise — one short section, not a treatise.

**Test scenarios:**
- None (doc-only).

**Verification:**
- `CLAUDE.md` wording reflects the shipped reality.
- A new contributor can read CLAUDE.md and understand when to add a `.rss` entry vs. when the request is out of scope.

## System-Wide Impact

- **Interaction graph:** No new dispatch branches in `StatusManager`. Existing `.rss` case handles the new entries. No Views changes (no new ProviderType case).
- **Error propagation:** RSS parse failures → existing `updateSnapshot(for:error:)` path, same as other `.rss`-typed entries today.
- **State lifecycle risks:** None new. RSS entries round-trip through Codable identically to existing ones.
- **API surface parity:** `ProviderType` enum unchanged. `CatalogEntry` schema unchanged.
- **Integration coverage:** `Catalog.shared` load path asserts on duplicate IDs — covered by existing assertion. Polling pipeline unchanged.
- **Precedent:** Several catalog entries are already `type: "rss"` (AWS, GCP, etc.). This plan adds more of the same shape — zero new architecture.

## Risks & Dependencies

- **Vendor feed URL drift.** Vendors occasionally change their RSS URL (e.g., `/feed` → `/feed/rss`). Mitigation: URL is in `catalog.json`, easy to update. Not a parser-code issue.
- **Heuristic blind spots.** If a vendor's phrasing doesn't match any current keyword, items classify as `.unknown`. User sees "Unknown" in the app — visible, not silent. Unit 3 extends keywords for observed gaps.
- **Cross-vendor heuristic conflicts.** A new keyword helpful for Vendor A might shift Vendor B's classification. Guardrail: full `CloudProviderRSSTests` + per-vendor tests run on every heuristic change.
- **RSS feeds themselves go down.** Vendor's status page can break its own RSS. Same failure mode as any other poll — surfaces as an `error` on the snapshot, graceful.
- **Microsoft 365 is dropped from scope.** A real coverage gap remains for enterprise users who care specifically about M365. Document the drop; revisit if a data source becomes available.
- **Plan #001 dependency.** Plan #001 Unit 3's Atlassian discovery must land first so Fastly, Docker Hub, and any other Atlassian-hosted vendors from the original gap list are handled through the correct pipeline. If Plan #001 is delayed, Unit 1 of this plan can still proceed but with the explicit note that post-Plan-001 the catalog may absorb more of the list automatically.

## Alternatives Considered

- **Custom parsers with `ProviderType.custom` + registry** (original plan 2 draft). Rejected: ~70% more code and maintenance than RSS-first, for identical user-visible coverage when feeds exist. Kept as a last-resort fallback in Unit 4 for vendors without feeds.
- **Consume an aggregator API (StatusGator, IsDown)**. Rejected: adds a paid/external dependency, and ToS for data-consumption tiers varies. Building on vendor-published RSS keeps us first-party and free.
- **LLM vision parsing (screenshot → structured status)**. Rejected: cost per poll, latency, reliability all worse than a 1KB RSS fetch. Possibly interesting for future "no-feed" vendors but massive overkill for current gap.
- **Defer entirely until Pro waitlist signal (N1-N3)**. Considered. Rejected because the RSS-first version is cheap enough (~2-3 days, near-zero ongoing maintenance) to ship as a modest coverage improvement without demand gating. The more expensive custom-parser version was what needed the demand gate, and it's not being built.

## Documentation / Operational Notes

- No weekly CI, no drift alerts, no new infrastructure. Maintenance model: if a user reports a vendor's status is wrong, investigate; likely a heuristic gap that extends in a small PR.
- Downgrade / persistence: existing `.rss` handling is already in release builds, no Codable migration concerns.
- Unit 1's audit artifact is the living reference for which feed URL each vendor uses. Link it from CLAUDE.md.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md](../brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md) — requirements N8-N11, B26.
- Existing RSS infrastructure: `Services/RSSParser.swift`, `Services/StatusManager.swift` (`rssStatusHeuristic`, `parseRSS`).
- Existing test precedent: `StatusMonitorTests/RSSParserTests.swift`, `StatusMonitorTests/CloudProviderRSSTests.swift`.
- Data model: `Models/Models.swift` (`ProviderType`, `ComponentStatus`).
- Scope constraint being softened: `CLAUDE.md` line — current wording quoted in Unit 5.
- Related plan: [2026-04-18-001-feat-ct-log-catalog-discovery-plan.md](./2026-04-18-001-feat-ct-log-catalog-discovery-plan.md) — covers Atlassian-hosted vendors (Fastly, Docker Hub, etc.) that appeared in the original B26 list.
