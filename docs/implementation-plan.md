# Storytime Implementation Plan (Deploy-First)

## Phase 0 - Bootstrapped and live
- [x] Minimal Elixir API shell in repo
- [x] `GET /` and `GET /health`
- [x] First Render web service creation and continuous deploy from GitHub
- [x] Baseline `render.yaml`

## Phase 1 - Spec skeleton
- [x] Phoenix app foundation (Endpoint, Router, Channel skeleton)
- [x] Postgres + Valkey resources provisioned on Render
- [x] Editor and Reader SPA scaffolds
- [x] Story/Cast/Pages/Music minimal type contracts

## Phase 2 - Authoring protocol and persistence
- [x] Ecto schemas/migrations for core story entities
- [x] `story:{story_id}` channel join + CRUD events
- [x] Editor tab UI wired to channel events
- [x] Generation queue state tracking surface

## Phase 3 - Generation pipeline and assets
- [x] Oban setup + worker implementation
- [x] Image/TTS/Music integrations with retries
- [x] Asset persistence under `/app/assets/{story_id}`
- [x] StoryPack assembler and `GET /api/stories/:id/pack`

## Phase 4 - Reader + collaboration + deploy
- [x] Reader rendering, playback, word highlighting
- [x] InstantDB collaboration states
- [x] Deploy worker to create per-story Render static site
- [ ] End-to-end verification checklist run (script scaffold committed in `scripts/verify_ac.sh`)
