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
