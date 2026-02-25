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
| FR-010..FR-014 Editor real-time protocol | Partial | Full `story:{id}` join + required mutation/generation/deploy events and persisted writes are live, with contract tests tracking required FR-011/FR-012 event coverage; payload-shape parity rehearsal is still in progress. |
| FR-015..FR-023 Generation pipeline | Partial | Oban-backed image/TTS/music/deploy workers are live with retries, staged `generation_progress`, and failure broadcasts; fallback providers were removed so failures surface explicitly per spec semantics. |
| FR-024..FR-030 Asset pipeline + StoryPack | Done | Deterministic `/app/assets/{story_id}` pathing, asset naming, `/assets/*` serving, StoryPack assembly endpoint, absolute URLs, and schema versions are implemented. |
| FR-031..FR-039 Reader experience | Partial | Reader implements loading/error states, scene rendering, navigation/swipe, narration/dialogue playback, word highlighting, narrate/read-alone mode, and music crossfade/volume; final UX polish remains. |
| FR-040..FR-044 Collaboration | Partial | Reader now uses InstantDB room collaboration (presence, host page sync, pointer sharing) with visible errors when misconfigured; multi-device verification is still in progress. |
| FR-045..FR-050 Deploy + provisioning | Partial | Deploy worker validates subdomain/content, assembles StoryPack JSON, provisions/updates per-story Render static sites, and persists deploy metadata; live-cycle rehearsal remains. |
| FR-051..FR-054 Operability | Partial | `/health` now reports clean checks (including writable assets disk), migration on startup is enabled, template/static services are present, and API build/runtime guards include regression tests + dialyzer. |

## Non-Functional Snapshot

| NFR Group | Status | Notes |
|---|---|---|
| Performance | Not started | No benchmark instrumentation yet. |
| Reliability | Partial | Continuous Render deploys, Oban durability, and bounded retries are in place; current hardening focus is full AC rehearsal and multi-device collaboration validation. |
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
