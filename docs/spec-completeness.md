# Storytime Spec Completeness (Implementation Snapshot)

This tracks current implementation coverage against the main spec requirement groups.

Legend:
- `Done`: implemented and live on Render
- `Partial`: scaffolded/stubbed, not yet complete
- `Not started`: not implemented yet

## Functional Requirement Groups

| Area | Status | Notes |
|---|---|---|
| FR-001..FR-009 Authoring + story data | Done | Persisted story/character/page/dialogue/music CRUD with slug uniqueness/normalization, page reordering, and preview from canonical StoryPack. |
| FR-010..FR-014 Editor real-time protocol | Partial | Full `story:{id}` join + required mutation/generation/deploy events and persisted writes are live, with contract tests tracking required FR-011/FR-012 event coverage and declared minimum payload keys for required FR-012 broadcasts. Additional dialogue-centric flows (`generate_dialogue`, `generate_all_dialogue`) and queue-aware editor controls are now implemented, including enriched per-job runtime diagnostics (speaker/page/text context, queue position, retries, attempt metadata) plus one-click retry for failed generation jobs; full payload-shape parity rehearsal is still in progress. |
| FR-015..FR-023 Generation pipeline | Partial | Oban-backed image/dialogue/TTS/music/deploy workers are live with retries, staged `generation_progress`, and failure broadcasts. New page-level `generate_dialogue` flow now generates dialogue via LLM and immediately queues ElevenLabs voice jobs using character voice IDs. Image/TTS/music workers now short-circuit to previously persisted asset URLs to avoid duplicate provider work on retries. |
| FR-024..FR-030 Asset pipeline + StoryPack | Done | Deterministic `/app/assets/{story_id}` pathing, asset naming, `/assets/*` serving, StoryPack assembly endpoint, absolute URLs, and schema versions are implemented. |
| FR-031..FR-039 Reader experience | Partial | Reader implements loading/error states, scene rendering, navigation/swipe, narration/dialogue playback, page dialogue sequence controls, active speaker highlighting, word highlighting, narrate/read-alone mode, and music crossfade/volume with span loop semantics and fade-out when leaving music spans; final UX polish remains. |
| FR-040..FR-044 Collaboration | Partial | Reader now uses InstantDB room collaboration (presence, host page sync, pointer sharing) with visible errors when misconfigured; identity is now stable for the browser session via session storage and host page sync is explicitly host-only. Multi-device verification is still in progress. |
| FR-045..FR-050 Deploy + provisioning | Partial | Deploy worker validates subdomain/content, assembles StoryPack JSON, provisions/updates per-story Render static sites, and persists deploy metadata; live-cycle rehearsal remains. |
| FR-051..FR-054 Operability | Partial | `/health` now reports clean checks (including writable assets disk), migration on startup is enabled, template/static services are present, and API build/runtime guards include regression tests + dialyzer. |

## Non-Functional Snapshot

| NFR Group | Status | Notes |
|---|---|---|
| Performance | Not started | No benchmark instrumentation yet. |
| Reliability | Partial | Continuous Render deploys are now CI-gated in GitHub Actions (prod compile + tests + dialyzer + blueprint validate + deploy polling), and Oban durability/bounded retries are in place; remaining hardening is full AC rehearsal and multi-device collaboration validation. |
| Scalability | Not started | No load testing yet. |
| Security/integrity | Partial | Secrets are in Render env vars, CORS origin handling is regression-tested to avoid runtime crashes, and API compile/runtime guards run locally before deploy. |
| Cost/efficiency | Partial | Running on starter/basic tiers; generation cost controls pending. |
| Experienceability | Partial | Editor/reader are mobile-usable with core controls exposed; final aesthetic and interaction polish remains. |

## Live Verification Endpoints

- API root: `https://storytime-api-091733.onrender.com/`
- Health: `https://storytime-api-091733.onrender.com/health`
- Version: `https://storytime-api-091733.onrender.com/api/version`
- StoryPack endpoint: `https://storytime-api-091733.onrender.com/api/stories/demo/pack`
- Editor probe: `https://storytime-editor-092113.onrender.com/`
- Reader probe: `https://storytime-reader-092117.onrender.com/`
