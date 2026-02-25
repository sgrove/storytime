# Storytime Implementation Plan (Deploy-First)

## Phase 0 - Bootstrapped and live
- [x] Minimal Elixir API shell in repo
- [x] `GET /` and `GET /health`
- [x] First Render web service creation and continuous deploy from GitHub
- [x] Baseline `render.yaml`

## Phase 1 - Spec skeleton
- [ ] Phoenix app foundation (Endpoint, Router, Channel skeleton)
- [ ] Postgres + Valkey resources in `render.yaml`
- [ ] Editor and Reader Vite React scaffolds
- [ ] Story/Cast/Pages/Music minimal type contracts

## Phase 2 - Authoring protocol and persistence
- [ ] Ecto schemas/migrations for core story entities
- [ ] `story:{story_id}` channel join + CRUD events
- [ ] Editor tab UI wired to channel events
- [ ] Generation queue state tracking surface

## Phase 3 - Generation pipeline and assets
- [ ] Oban setup + worker stubs
- [ ] Image/TTS/Music integrations with retries
- [ ] Asset persistence under `/app/assets/{story_id}`
- [ ] StoryPack assembler and `GET /api/stories/:id/pack`

## Phase 4 - Reader + collaboration + deploy
- [ ] Reader rendering, playback, word highlighting
- [ ] InstantDB collaboration states
- [ ] Deploy worker to create per-story Render static site
- [ ] End-to-end verification checklist run
