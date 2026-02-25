# Verification Tracker

## Implemented and live
- [x] `GET /health` returns `200`.
- [x] `GET /` API shell route returns HTML.
- [x] `GET /api/version` returns API metadata JSON.
- [x] `GET /api/stories` returns persisted story list when DB is available.
- [x] `POST /api/stories` creates persisted stories when DB is available.
- [x] `GET /api/stories/:id/pack` returns assembled StoryPack JSON from persisted graph.
- [x] Phoenix WebSocket endpoint available at `/socket`.
- [x] Channel `story:{story_id}` join implemented.
- [x] Persisted channel mutation events implemented: `update_story`, character/page/dialogue/music CRUD, and page reorder.
- [x] Generation/deploy channel triggers implemented: `generate_*`, `generate_all*`, `deploy_story`.
- [x] Page-level dialogue generation (`generate_dialogue`) now produces dialogue text from LLM context and queues voice generation jobs in the same flow.
- [x] Story-wide dialogue generation trigger (`generate_all_dialogue`) now enqueues dialogue generation for pages missing dialogue lines.
- [x] Oban generation/deploy jobs are enqueued and projected via `generation_jobs`.
- [x] Asset files are persisted under deterministic `/app/assets/{story_id}` naming.
- [x] Story status transitions now enforce `draft/generating/ready/deployed` flow for generation/deploy events.
- [x] Deploy input validation rejects invalid subdomain and missing-content deploy attempts before enqueue.
- [x] Reader supports navigation, narration/dialogue playback, explicit page dialogue and narration+dialogue sequence controls, active speaker highlighting, word highlighting, narrate/read-alone mode, and music crossfade/volume.
- [x] Reader music playback now respects span `loop` behavior and fades out when moving to pages outside any music span.
- [x] Editor now supports ElevenLabs voice-picking via `/api/voices/elevenlabs`, one-click `Generate Dialogue + Voices`, inline dialogue audio playback, and job/progress indicators.
- [x] Generation queue diagnostics now include dialogue_tts-specific context (speaker/page/text preview), queue position, age, Oban state/attempt details, and retry timing.
- [x] FR-012 broadcast payload minimum-key contract is now explicitly declared in `StoryChannel.required_broadcast_payload_keys/0` and regression-tested.
- [x] Reader collaboration uses InstantDB room model (presence, host page sync, pointers) with explicit misconfiguration errors.
- [x] Render API service deploy from GitHub is active.
- [x] Render managed Postgres provisioned and wired via `DATABASE_URL`.
- [x] Render managed Key Value instance is provisioned (`storytime-kv`).
- [x] Render persistent disk is attached to API service (`/app/assets`) and health check reports writable.
- [x] Editor static service and reader static service are deployed.
- [x] CORS configuration tightened to localhost + onrender origins.
- [x] CORS regression tests added for `/health` requests with/without `Origin`, preventing prior FunctionClause crash.
- [x] Local dialyzer runs clean (`mix dialyzer`) as a pre-deploy API guard.
- [x] Generation workers now emit staged `generation_progress` updates and no longer silently fallback to non-spec providers.
- [x] Image/TTS/music workers now reuse existing persisted asset URLs for the same target, preventing duplicate provider generation work on retries.
- [x] GitHub Actions CD now runs compile/test/dialyzer guards, validates `render.yaml` via Render CLI, and triggers/polls API/editor/reader deploys on pushes to `main`.
- [x] Reader identity is now session-stable (ephemeral, no login) and host page sync broadcasts are host-only.

## In progress
- [ ] Full event payload parity across every FR-012 broadcast shape.
- [ ] End-to-end multi-device verification for InstantDB collaboration behavior.
- [ ] Formal AC-001..AC-015 scripted verification run and recorded artifacts (`scripts/verify_ac.sh` scaffold added).
