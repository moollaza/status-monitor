---
title: "feat: CT log catalog discovery pipeline"
type: feat
status: active
date: 2026-04-18
deepened: 2026-04-18
origin: docs/brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md
---

# feat: CT log catalog discovery pipeline

## Overview

Add a Certificate Transparency (CT) log mining pipeline to discover Atlassian-Statuspage-hosted services at scale. Grows `Resources/catalog.json` toward **5,000+ verified Atlassian-hosted services** with minimal manual curation. Reuses the existing `discover-services.py` / `merge-and-verify.py` verification pipeline — after first fixing a pre-existing platform-classification bug in both scripts.

The unlock: Atlassian packs ~40 customer custom-domains into each shared Let's Encrypt SAN certificate. Every SAN entry in CT logs is a near-certain Statuspage customer. `crt.sh` exposes this via a free JSON API.

**Plan runs entirely on GitHub Actions — no local long-running jobs required.**

## Problem Frame

The current catalog (1,686 services) is the verified merge of MIT-licensed source lists (`awesome-status-urls.json`, `statusphere-urls.json`). Those sources are exhausted as a yield path. Continued manual curation doesn't scale.

Per the origin document (N12-N15): CT log mining is the genuinely new path to 5,000+ services. Weekly re-run catches newly-onboarded Atlassian customers without human effort.

## Requirements Trace

- R1. Build a discovery pipeline that extracts candidate domains from CT logs via `crt.sh` (N12 in origin).
- R2. Pipeline integrates with the existing `discover-services.py` / `merge-and-verify.py` verification path (N12 in origin).
- R3. **Grow catalog toward 5,000+ Atlassian/incident.io-hosted services.** Actual yield depends on the CT + verification pipeline's real-world hit rate, which is validated by the pilot in Unit 1 before committing to a hard target (N13 in origin).
- R4. Pipeline is runnable manually via `workflow_dispatch` and on a weekly automated cron — both on GitHub Actions, no local machine required (N14 in origin).
- R5. Discovery-gap services on **Atlassian infrastructure** flagged in the origin doc (Docker Hub, PagerDuty, Mailchimp, Databricks, Hugging Face, Mistral, Perplexity, Pipedrive, Replit, Deel) should flow in when their status pages are Atlassian-hosted. Services on incident.io or other platforms are covered by a separate discovery approach out of scope here (B25 in origin).
- R6. **Pre-existing platform-classification bug in `discover-services.py` and `merge-and-verify.py` must be fixed before bulk ingestion**, and existing catalog entries relabeled. Without this fix, CT mining amplifies the bug across thousands of new entries.

## Scope Boundaries

- **Out of scope:** Scraping commercial aggregators (StatusGator, IsDown) — ToS risk per B24.
- **Out of scope:** incident.io discovery via CT — incident.io's custom domains don't follow the Atlassian shared-SAN pattern. Separate approach needed, deferred.
- **Out of scope:** Automated PR merging. The weekly cron files an auto-PR; a human reviews and merges.
- **Out of scope:** Category assignment. New entries default to `"Uncategorized"`; `scripts/auto-categorize.py` is a separate manual run.
- **Out of scope:** Non-Atlassian custom status pages (covered by plan #002).
- **Out of scope:** Performance optimization of `Catalog.shared.search()` — O(n) at 5k entries is likely fine; revisit only if observable jank appears.

## Context & Research

### Relevant Code and Patterns

- `scripts/discover-services.py` — URL-pattern + `/api/v2/summary.json` probe logic. **Contains the platform-classification bug** at lines 47-50: `platform = "atlassian" if (has_incidents or has_scheduled) else "incident.io"` — checks truthiness of potentially-empty arrays. Needs fix (see Unit 0).
- `scripts/merge-and-verify.py` — source JSON loader + dedup + verification pipeline. **Contains the same bug** at lines 48-50. Writes `scripts/new-verified.json`. Serial (single-threaded urllib + `time.sleep`). Will need concurrency for CT scale.
- `scripts/audit-catalog.py` — post-merge validation that every `base_url` still returns valid JSON. Already called after merge.
- `Resources/catalog.json` — flat JSON array of `{id, name, base_url, type, category, platform}`. Current platform distribution (`atlassian: 382, incident.io: 1301`) is evidence of the classification bug — real market share is ~opposite.
- `Models/Models.swift: Catalog.shared` — synchronous load + sort at startup. At 5k entries <50ms. O(n) search function at `search()` (line 58) will scan 5k entries per keystroke; probably fine, flag only if jank appears.
- `scripts/awesome-status-urls.json`, `scripts/statusphere-urls.json` — source files, shape: `[{"name", "url"}]`. New CT output matches this shape.
- User-Agent convention: `StatusMonitor-Discovery/1.0`. Use `StatusMonitor-CT/1.0` for CT-specific crt.sh traffic.

### Institutional Learnings

No `docs/solutions/` entries — no prior art in this repo.

### External References

- [crt.sh JSON API](https://crt.sh/?output=json) — free, no auth. Supports `q=%25.statuspage.io` (URL-encoded `%.statuspage.io`) for wildcard subdomain queries. Returns JSON array of certificate records with `name_value` containing newline-delimited SANs. Known to truncate large result sets (~10k row cap observed) and degrade under load. Prudent throttling: ≥3s between paginated requests.
- [Atlassian shared SAN docs](https://support.atlassian.com/statuspage/docs/set-a-custom-domain-and-ssl/) — confirms Let's Encrypt batching of ~40 customer domains per cert.
- crt.sh **does not** support querying by issuer fingerprint alone as a top-level operation. The realistic path is: query `%.statuspage.io` → for each returned cert, pull the full SAN list → harvest customer custom-domains that co-appear on those certs.

## Key Technical Decisions

- **Fix the platform-classification bug first (Unit 0)**, before any CT mining. Without this, every existing catalog entry is mislabeled, and CT would add thousands more mislabeled entries. Fix is trivial: replace `bool(j.get(...))` truthy checks with `key in j` presence checks. Also requires a one-time pass to relabel existing catalog entries by probing their `base_url` and re-classifying.
- **CT query strategy: SAN harvesting, not issuer walk.** Phase 1: query `crt.sh` for `%.statuspage.io` — returns certs whose SAN list includes a `*.statuspage.io` hostname, plus co-appearing customer custom-domains in the same cert. Phase 2: for each cert with ≥20 SAN entries AND ≥1 statuspage.io entry, harvest all non-statuspage.io SANs as candidate customer domains. Dedupe normalized hostnames. This replaces the prior (infeasible) "issuer-fingerprint walk" design.
- **Unified workflow for first run + weekly cron.** Same `.github/workflows/catalog-discovery.yml` handles both, triggered via `workflow_dispatch` for the initial bootstrap and `schedule` for ongoing. No local long-running jobs. No duplicate Python setup.
- **Concurrent verification** to fit in the 6-hour GitHub Actions job limit. `merge-and-verify.py` gets a `--concurrency N` flag (default 20). 5k candidates × 0.5s/request ÷ 20 workers ≈ 2 minutes at steady-state; worst case (timeout-heavy long tail) ≈ 30 min. Well under the 6h cap.
- **Explicit false-positive detection budget.** Augment `merge-and-verify.py`'s verification with structural checks: require `components` present (may be empty list, but key must exist), `page.url` host matches requested host, `status.indicator` in `{"none","minor","major","critical","maintenance"}`. Rejects generic JSON endpoints that accidentally match the `{page, status}` shape.
- **Output candidates as `scripts/ct-urls.json`** matching the shape of existing source files. Lets `merge-and-verify.py` ingest via one line of config change. Zero churn to downstream verification.
- **Run crt.sh pagination at 3s intervals**; run candidate verification at 0.3s base intervals but parallelized across 20 workers. These two rate-limit domains are distinct.
- **First Python tests in the repo.** Add `scripts/tests/` with `pytest`-based unit tests for SAN extraction + candidate synthesis + platform classification (deterministic, no network). Add a Python test job to `.github/workflows/ci.yml` so PRs gate on them.
- **Weekly GitHub Action auto-PR, not auto-merge.** Human review prevents silent catalog corruption.
- **Atomic writes for `scripts/ct-urls.json`.** Only replace the file on full-success pagination. Partial crt.sh failures must not produce a truncated file that `merge-and-verify.py` silently consumes.

## Open Questions

### Resolved During Planning

- **Q:** Do we need to fix the platform-classification bug, or can we re-label later? **A:** Fix first. Amplifying the bug across thousands of new entries, then re-labeling, is strictly more work than fixing once and ingesting correctly.
- **Q:** Should Unit 3 (first full run) be local or remote? **A:** Remote via `workflow_dispatch`. Collapse with the weekly workflow. User's laptop doesn't need to stay online.
- **Q:** Does the plan need a separate fallback if crt.sh is unavailable? **A:** No. Weekly cadence limits impact; weekly cron just skips that week. Multi-provider CT support is deferred.
- **Q:** What is the yield target — 5,000 hard, or aspirational? **A:** Aspirational. Pilot query in Unit 1 validates realistic yield before committing to a number.

### Deferred to Implementation

- Exact crt.sh pagination parameters (`limit`, `exclude`, etc.) — tune against live API.
- Exact SAN-cluster cert filter thresholds (min SAN count, renewed/revoked handling) — will be a tunable constant, flag in code.
- Custom-domain ↔ slug aliasing dedup: when CT finds `status.foo.com` but catalog already has `foo.statuspage.io` for the same vendor, dedup misses. Mitigation during implementation: after verification, compare `page.url` (returned by summary.json) against catalog `base_url`s as a secondary dedup pass.
- GitHub Action PR body template.
- Whether `auto-categorize.py` copes with 3k+ uncategorized entries — spot-check after first run; if coverage is <50%, improve heuristics as follow-up.

## Implementation Units

- [ ] **Unit 0: Fix platform-classification bug + relabel existing catalog**

**Goal:** Correct the pre-existing bug in `discover-services.py` and `merge-and-verify.py` that labels Atlassian pages with no current incidents as `incident.io`. Relabel existing catalog entries before amplifying the bug via CT mining.

**Requirements:** R6

**Dependencies:** None. Ships before all other units.

**Files:**
- Modify: `scripts/discover-services.py` (platform detection at lines 47-50)
- Modify: `scripts/merge-and-verify.py` (platform detection at lines 48-50)
- Modify: `Resources/catalog.json` (relabeled entries)
- Create: `scripts/tests/__init__.py`
- Create: `scripts/tests/test_platform_detection.py`
- Create: `scripts/relabel-catalog.py` (one-shot script: probe each catalog entry's URL, re-classify using corrected logic, write back)

**Approach:**
- Replace `bool(j.get("scheduled_maintenances"))` truthy check with `"scheduled_maintenances" in j` key-presence check. Atlassian Statuspage responses always include `scheduled_maintenances` (as a possibly-empty array); incident.io responses don't. Key presence is the correct signal.
- Apply the fix identically in both scripts.
- One-shot relabel: iterate `Resources/catalog.json`, probe each `base_url` + `/api/v2/summary.json`, reclassify. Entries whose URLs now fail verification (rare but possible on vendor changes) stay labeled as they are; flag for manual review.
- Add pytest fixture tests: sample Atlassian response (with empty `scheduled_maintenances: []`) → classifies as `atlassian`; sample incident.io response (no `scheduled_maintenances` key) → classifies as `incident.io`; sample response missing both structural markers → raises error.

**Execution note:** Ship the script fix and tests as one PR. Run the relabel separately; review the diff before merging.

**Patterns to follow:**
- `scripts/audit-catalog.py` — probe-and-update pattern, URL construction, timeout + SSL context setup.

**Test scenarios:**
- Happy path — Atlassian-shaped response (with `scheduled_maintenances: []`) classifies as `atlassian`.
- Happy path — incident.io-shaped response (no `scheduled_maintenances` key) classifies as `incident.io`.
- Happy path — Atlassian-shaped response with populated `scheduled_maintenances` still classifies as `atlassian` (regression check — the existing "works when non-empty" case must keep working).
- Edge case — response missing both `page` and `status` raises the existing "not a valid status page" error (unchanged behavior).
- Edge case — response with `scheduled_maintenances: null` classifies as `atlassian` (key present, value null — still Atlassian schema).
- Integration — running `relabel-catalog.py` on a hand-crafted 5-entry fixture updates the `platform` field per the corrected rules; entries whose URLs now fail are flagged unchanged.

**Verification:**
- `python3 -m pytest scripts/tests/test_platform_detection.py` passes.
- After `scripts/relabel-catalog.py` runs, the ratio shifts meaningfully from the current 382/1301 (atlassian/incident.io) split — expect roughly inverted (e.g. ~1300/380 or similar depending on real platform distribution).
- `python3 scripts/audit-catalog.py` continues to pass after the relabel.

---

- [ ] **Unit 1: CT log query + SAN extraction module**

**Goal:** Fetch certificates from `crt.sh` matching `%.statuspage.io`, extract co-appearing customer custom-domains from the same certs, normalize, dedupe, and write candidates to `scripts/ct-urls.json`. Run a pilot to validate realistic yield before committing to R3's target.

**Requirements:** R1, R3

**Dependencies:** Unit 0.

**Files:**
- Create: `scripts/discover-from-ct.py`
- Create: `scripts/ct-urls.json` (gitignored until first populated run)
- Create: `scripts/tests/test_discover_from_ct.py`

**Approach:**
- **Phase 1:** GET `https://crt.sh/?q=%25.statuspage.io&output=json` (paginated via `limit` param + time-bounded `exclude`). Respect `time.sleep(3)` between paginated requests. Parse JSON array; extract `name_value` field (newline-delimited SANs) from each cert.
- **Phase 2:** For each cert, if SAN count ≥20 AND contains ≥1 `*.statuspage.io` entry, treat it as a shared-SAN Atlassian cluster cert. Harvest all *other* SANs in that cert's `name_value` as candidate customer domains.
- **Normalize:** lowercase, strip trailing dot, filter wildcards (`*.foo`), filter bare TLDs, filter entries already present in catalog's `base_url` set.
- **Synthesize candidate URL:** `https://{san}` for subdomain-shaped SANs (the common case).
- **Name derivation:** strip `status.` prefix and `.com/.io/.net/.co/.app` TLDs; title-case the remainder. If the result is empty or <3 chars, fall back to the full SAN itself as the name. `merge-and-verify.py` will call `/api/v2/summary.json` and use the real `page.name` anyway.
- **Atomic write:** build the full candidate list in memory, write to `scripts/ct-urls.json.tmp`, rename to `scripts/ct-urls.json` only on full success. Partial crt.sh failure → exit non-zero, don't replace the file.
- **Pilot mode:** `--pilot` flag limits pagination to ~500 candidate extraction to validate shape + rate-limit tolerance before the full run. Run pilot once during planning validation; don't block Unit 2 on pilot completion.

**Patterns to follow:**
- `scripts/discover-services.py` — SSL context, User-Agent, timeout handling.
- `scripts/merge-and-verify.py` — URL normalization (`rstrip("/").lower()`).

**Test scenarios:**
- Happy path — given a sample crt.sh JSON response, extract SANs correctly into candidate objects.
- Happy path — cert with ≥20 SANs and ≥1 statuspage.io entry yields customer candidates from the non-statuspage.io SANs.
- Edge case — cert with <20 SANs is skipped (not a shared-SAN cluster cert).
- Edge case — `name_value` with mixed newlines (`\n`, `\r\n`) parses correctly.
- Edge case — wildcard SAN (`*.example.com`) is filtered out.
- Edge case — bare TLD or empty string is filtered out.
- Edge case — duplicate SANs across different cert records collapse to a single candidate.
- Edge case — SAN already present in `Resources/catalog.json` (by normalized URL) is excluded from output.
- Edge case — name derivation on a SAN that strips to empty falls back to the raw SAN.
- Error path — crt.sh returns HTTP 500 mid-pagination → script exits non-zero, `ct-urls.json` is not replaced.
- Error path — crt.sh returns HTML under load instead of JSON → `json.JSONDecodeError` is caught, script exits non-zero.
- Error path — crt.sh returns empty JSON array → script exits with a clear "no candidates discovered" message.
- Error path — cert record missing `name_value` field is skipped with a warning, not fatal.
- Happy path — output JSON file matches the source-file shape expected by `merge-and-verify.py`.

**Verification:**
- `python3 scripts/discover-from-ct.py --pilot` completes in <5 minutes, writes a ~500-entry pilot file, and logs the observed yield rate so we can extrapolate full-run behavior.
- `python3 -m pytest scripts/tests/` passes.

---

- [ ] **Unit 2: Add concurrency + structural FP checks to `merge-and-verify.py`, integrate CT source**

**Goal:** (a) Add `--concurrency N` parallel-verification support to `merge-and-verify.py` so 3k-8k candidates fit in a 6-hour job. (b) Add structural FP checks to reject generic `{page, status}` JSON that isn't actually a Statuspage. (c) Include `scripts/ct-urls.json` as a source.

**Requirements:** R2, R3

**Dependencies:** Unit 0, Unit 1.

**Files:**
- Modify: `scripts/merge-and-verify.py`

**Approach:**
- **Concurrency:** replace the serial verification loop with a `concurrent.futures.ThreadPoolExecutor` (default max_workers=20, overridable via `--concurrency`). Preserve the per-request `time.sleep(args.delay)` as a per-worker floor to avoid DDoS patterns; the effective global rate is `workers / delay`.
- **Structural FP checks:** after decoding `/api/v2/summary.json`, require all of: `components` key present (list, possibly empty), `page.url` present and its host matches the requested host (normalize for `www.` prefix), `status.indicator` in `{"none","minor","major","critical","maintenance"}`. Any failure → reject as "not a valid status page."
- **Source integration:** add `("ct", "scripts/ct-urls.json")` to the sources list.
- **Progress logging** every 100 entries (already present, keep).

**Patterns to follow:**
- Existing `sources` dict convention — additive.
- Standard library `concurrent.futures` — no new dependencies.

**Test scenarios:**
- Happy path — `merge-and-verify.py --concurrency 10` completes against a 100-entry hand-crafted `ct-urls.json` fixture with expected yield, platform classification, and no mixed-order output corruption.
- Happy path — structural FP check accepts a valid Atlassian response.
- Edge case — structural FP check rejects a JSON response with `{page, status}` but missing `components` key.
- Edge case — structural FP check rejects a response where `page.url` host doesn't match the requested host (e.g. redirect to a different domain serving unrelated JSON).
- Edge case — structural FP check accepts `status.indicator == "none"` (operational) and `"maintenance"` — common valid values.
- Edge case — structural FP check rejects `status.indicator == "ok"` (non-enum value).
- Integration — CT-sourced entries in `new-verified.json` carry the corrected `platform` classification from Unit 0.
- Integration — entries already in `catalog.json` (by normalized URL) are filtered even when they appear in `ct-urls.json`.

**Verification:**
- `python3 scripts/merge-and-verify.py --concurrency 20 --limit 200` completes in under 2 minutes against a test candidate list and reports structural-FP rejections in the summary.

---

- [ ] **Unit 3: Unified discovery workflow (first run + weekly cron)**

**Goal:** Single GitHub Actions workflow runs the full pipeline end-to-end. Manual `workflow_dispatch` triggers the first bootstrap run. Scheduled `cron` runs weekly thereafter. Auto-opens a PR with new verified entries for human review. **No local long-running job required.**

**Requirements:** R3, R4, R5

**Dependencies:** Unit 0, Unit 1, Unit 2.

**Files:**
- Create: `.github/workflows/catalog-discovery.yml`

**Approach:**
- **Triggers:** `workflow_dispatch:` (manual) + `schedule: - cron: '0 8 * * 1'` (Monday 08:00 UTC).
- **Runner:** `ubuntu-latest`. No macOS needed (Python only).
- **Permissions:** `contents: write`, `pull-requests: write` (required for PR creation via default `GITHUB_TOKEN`).
- **Timeout:** 5 hours 30 minutes (under GitHub's 6h hard limit; leaves margin).
- **Steps:**
  1. Checkout with `actions/checkout@<pinned-sha>`.
  2. Setup Python 3.11 with `actions/setup-python@<pinned-sha>`.
  3. `pip install pytest` (for the `merge-and-verify.py` concurrency tests if gated inline).
  4. `python3 scripts/discover-from-ct.py` (full run, not pilot).
  5. `python3 scripts/merge-and-verify.py --concurrency 20 --delay 0.3`.
  6. If `scripts/new-verified.json` has ≥1 entry: merge into `Resources/catalog.json` (small helper step inline, or a dedicated `scripts/merge-new-verified.py`), run `python3 scripts/audit-catalog.py`, then open PR via `peter-evans/create-pull-request@<pinned-sha>`.
  7. If `new-verified.json` is empty, log "no new entries this run" and exit 0.
- **PR body template:** summary of yield, platform breakdown, top 20 new entries by name, reminder that categories default to Uncategorized, link to this plan.
- **PR title:** `catalog: weekly CT discovery — N new services`.
- **Do not auto-merge.** Human review prevents silent catalog corruption.
- **GITHUB_TOKEN vs PAT:** default `GITHUB_TOKEN` creates the PR but that PR does not trigger subsequent workflow runs. Because `audit-catalog.py` runs *inside this workflow* before PR creation, the ci.yml re-verification isn't essential. If we later want ci.yml to re-run on bot PRs, switch to a PAT stored in repo secrets — deferred.

**Patterns to follow:**
- `.github/workflows/ci.yml` — security posture (pinned SHAs, concurrency group, timeout, no untrusted input interpolation).
- `.github/workflows/deploy-website.yml` — workflow structure.

**Test scenarios:**
- Integration — manual `workflow_dispatch` completes and opens a PR when CT yields ≥1 new entry.
- Integration — workflow is a no-op (no PR) when CT yields zero new entries.
- Integration — workflow fails cleanly (non-zero exit, visible in Actions UI) when `crt.sh` is unreachable; no partial PR is opened.
- Integration — PR contains corrected `platform` labels (leveraging Unit 0's fix).
- Integration — structural-FP-rejected entries do not appear in the PR (leveraging Unit 2's checks).

**Verification:**
- Manual `workflow_dispatch` run completes within the 5h30m timeout and opens a PR (if yield > 0).
- After PR merge, `Resources/catalog.json` grows and `python3 scripts/audit-catalog.py` exits 0.
- First successful run is the bootstrap (R3 "grow catalog toward 5,000+"). Subsequent weekly runs catch new customers.

---

- [ ] **Unit 4: Add Python test job to CI**

**Goal:** Ensure `scripts/tests/` pytest tests run on every PR, not just weekly. Catches Python script regressions at review time.

**Requirements:** R6 (via test coverage of Unit 0 fix).

**Dependencies:** Unit 0.

**Files:**
- Modify: `.github/workflows/ci.yml`

**Approach:**
- Add a new job `python-tests` that runs on `ubuntu-latest` (no Xcode needed) in parallel with the existing macOS `build-and-test` job.
- Steps: checkout → setup Python 3.11 → `pip install pytest` → `python3 -m pytest scripts/tests/`.
- Pin all action SHAs per existing security posture.
- Timeout: 5 minutes.
- Concurrency: inherits the workflow-level concurrency group.

**Patterns to follow:**
- Existing `build-and-test` job structure.
- Pinned action SHAs.

**Test scenarios:**
- Integration — a PR introducing a broken `discover-from-ct.py` fails the `python-tests` job.
- Integration — a PR with a passing script passes the job.

**Verification:**
- Both jobs appear in the PR checks UI. The Python job takes <1 minute.

---

- [ ] **Unit 5: Documentation update**

**Goal:** Document the new pipeline so contributors can understand, rerun, and maintain it.

**Requirements:** R4

**Dependencies:** Units 0-4.

**Files:**
- Modify: `CLAUDE.md` (catalog guidance section)
- Create: `scripts/README.md` (concise: purpose of each script, how to run pipeline manually, how the weekly workflow works, where to find logs)

**Approach:**
- Short "Catalog discovery pipeline" section covering: manual run via `workflow_dispatch`, weekly cron, expected yield, where to find logs.
- Update CLAUDE.md to mention `discover-from-ct.py` alongside the existing `scripts/discover-services.py` reference.
- Document the platform-classification fix (Unit 0) and why the catalog's platform field had been inverted.

**Test scenarios:**
- None (doc-only).

**Verification:**
- A new contributor can run the pipeline from documentation alone.

## System-Wide Impact

- **Interaction graph:** No runtime app code paths change. Pipeline is CI-only + one Swift-side consideration: `Catalog.shared.search()` performance at 5k+ entries. Expected fine on Apple Silicon; flag if jank appears.
- **Error propagation:** `crt.sh` unavailability → workflow failure (visible in Actions tab). Individual probe failures counted in summary. Atomic writes prevent partial ct-urls.json consumption.
- **State lifecycle risks:** Bulk catalog additions could include bad entries. Defenses: (1) Unit 2 structural FP checks at verification time; (2) `audit-catalog.py` runs inside the workflow before PR creation; (3) PRs don't auto-merge.
- **API surface parity:** `catalog.json` schema unchanged.
- **Integration coverage:** `Catalog.shared` load path assertion in DEBUG catches duplicate IDs or malformed entries.
- **Pre-existing bug amplification:** Addressed by Unit 0. Fix ships *before* CT ingestion.

## Risks & Dependencies

- **crt.sh availability / ToS change.** External dependency with no SLA. Weekly cadence limits impact. No alternate CT provider wired; consider censys.io if crt.sh becomes unreliable.
- **Yield shortfall.** Pilot in Unit 1 validates realistic yield. If <2,000 new candidates after structural FP rejections, the 5,000 aspirational target is out of reach from this pipeline alone. Escalation: broaden query (non-Let's-Encrypt issuers, incident.io path). Not blocking for v1.
- **False positives past structural checks.** Even with `components`/`page.url host match`/`status.indicator` checks, some non-Statuspage JSON endpoints may sneak through. Spot-check 20-30 entries manually during first run; tighten checks if significant drift emerges. Acceptable initial guard.
- **Catalog search performance at scale.** `Catalog.shared.search()` is O(n). At 5k entries ≈ 20k string ops per keystroke; fine on Apple Silicon, possibly visible on older Intel Macs. Monitor; optimize only if observable.
- **GitHub Actions public-repo free tier.** Unlimited minutes on public repos — no quota concern.
- **Platform-classification relabel may fail entries where URLs have changed.** Unit 0's relabel script flags these; manual review path.
- **Custom-domain ↔ slug aliasing dedup.** Mitigation during Unit 2 implementation: post-verification, compare `page.url` against catalog `base_url`s as a secondary dedup pass.

## Documentation / Operational Notes

- Weekly PR review becomes a light ongoing task (~10-15 min/week).
- First run (Unit 3) is fully remote — `workflow_dispatch` trigger, walk away, review PR when it opens.
- `crt.sh` User-Agent `StatusMonitor-CT/1.0` identifies our traffic.
- Unit 0's relabel is a one-shot; the fix to the detection logic means future runs stay correct.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md](../brainstorms/2026-04-11-statusmonitor-backend-service-requirements.md) — requirements N12-N15, B22-B25.
- Existing pipeline: `scripts/discover-services.py`, `scripts/merge-and-verify.py`, `scripts/audit-catalog.py`.
- Existing data sources: `scripts/awesome-status-urls.json`, `scripts/statusphere-urls.json`.
- External: [crt.sh](https://crt.sh/), [Atlassian Statuspage custom domain docs](https://support.atlassian.com/statuspage/docs/set-a-custom-domain-and-ssl/).
- Runtime code: `Models/Models.swift` (`Catalog.shared` load + search performance concern).
