defmodule StorytimeWeb.Router do
  use StorytimeWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", StorytimeWeb do
    pipe_through(:api)

    get("/health", HealthController, :show)
    get("/api/version", ApiController, :version)
    get("/api/music-tags", ApiController, :music_tags)
    get("/api/voices/:provider", ApiController, :voices)
    post("/api/voices/preview", ApiController, :voice_preview)

    get("/api/stories", ApiController, :stories)
    post("/api/stories", ApiController, :create_story)
    get("/api/stories/:id", ApiController, :show_story)
    get("/api/stories/:id/jobs", ApiController, :story_jobs)
    get("/api/stories/:id/pack", ApiController, :story_pack)
    get("/api/story-slugs/:slug/pack", ApiController, :story_pack_by_slug)
  end

  scope "/", StorytimeWeb do
    get("/", PageController, :index)
  end
end
