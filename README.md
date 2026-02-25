# Storytime

Deploy-first Storytime implementation for CodeTV.

Current live milestone includes:

- Phoenix API runtime on Render
- `GET /` HTML landing
- `GET /health`
- `GET /api/version`
- `GET /api/stories/:id/pack` (StoryPack scaffold)
- Phoenix socket endpoint at `/socket`
- `story:{id}` channel with join + CRUD stub events
- Managed Postgres provisioned and wired (`DATABASE_URL`)
- Editor and reader static placeholder services

Next milestones fill persistence-backed channel handlers, generation workers, full StoryPack assembly, reader runtime, and per-story deploy worker.

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
