# Verification Tracker

## Implemented and live
- [x] `GET /health` returns `200`.
- [x] `GET /` API shell route returns HTML.
- [x] `GET /api/version` returns API metadata JSON.
- [x] `GET /api/stories` returns persisted story list when DB is available.
- [x] `POST /api/stories` creates persisted stories when DB is available.
- [x] `GET /api/stories/:id/pack` returns StoryPack scaffold JSON.
- [x] Phoenix WebSocket endpoint available at `/socket`.
- [x] Channel `story:{story_id}` join implemented.
- [x] CRUD stub channel events implemented: `update_story`, `add/update/delete_character`, `add/update/delete_page`, `reorder_pages`.
- [x] Render API service deploy from GitHub is active.
- [x] Render managed Postgres provisioned and wired via `DATABASE_URL`.
- [x] Editor static service and reader static service are deployed.

## In progress
- [ ] Persist channel mutations to Postgres before ack.
- [ ] Full event matrix/broadcast parity with spec FR-011/FR-012.
- [ ] Oban jobs and generation queue projection.
- [ ] StoryPack assembler from persisted DB records + assets.
- [ ] Deploy worker for per-story reader static site provisioning.
