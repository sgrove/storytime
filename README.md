# Storytime

Bootstrap service for Storytime. Current milestone ships a minimal Elixir web service with:

- `GET /` basic HTML landing page
- `GET /health` health endpoint
- `GET /api/version` bootstrap metadata endpoint
- `GET /api/stories/:id/pack` StoryPack scaffold payload

This is the first deploy-first checkpoint before adding Phoenix/Channels/Oban/editor/reader components.
