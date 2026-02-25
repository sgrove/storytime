# Storytime

Deploy-first Storytime implementation for CodeTV.

Current live milestone includes:

- Phoenix API runtime on Render
- `GET /` HTML landing
- `GET /health`
- `GET /api/version`
- `GET /api/stories/:id/pack` (assembled StoryPack JSON)
- Phoenix socket endpoint at `/socket`
- `story:{id}` channel with persisted CRUD + generation/deploy events
- Managed Postgres provisioned and wired (`DATABASE_URL`)
- Oban workers for image/dialogue/TTS/music/deploy pipelines
- Deploy lifecycle hardening with structured failure diagnostics
- Generation guardrails (target/text/voice validation + capped jobs/request)
- Editor voice preview + strict voice selection UX
- Reader playback/collaboration runtime with host follow + stale peer cleanup

## Reader StoryPack Source Modes

- Template reader deployments can allow StoryPack override (`allowPackOverride: true`) so operators can load a pack via `?pack=<url>` or the in-app Story Source panel.
- Per-story standalone reader deployments are locked (`allowPackOverride: false`) and remain pinned to the configured `packUrl`.

## GitHub -> Render CD

This repo now includes `.github/workflows/render-cd.yml` to automate deploys on every push to `main`:

1. Run API guards (`MIX_ENV=prod mix compile`, `mix test`, `mix dialyzer`).
2. Validate `render.yaml` with Render Blueprint validation.
3. Trigger and poll Render deploys for API, editor, and reader until `live`.

Required GitHub Actions secret:

- `RENDER_API_KEY`

Optional GitHub Actions variables (defaults are in the workflow):

- `RENDER_WORKSPACE_ID`
- `RENDER_API_SERVICE_ID`
- `RENDER_EDITOR_SERVICE_ID`
- `RENDER_READER_SERVICE_ID`
