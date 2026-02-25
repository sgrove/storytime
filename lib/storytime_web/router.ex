defmodule StorytimeWeb.Router do
  use StorytimeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", StorytimeWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/api/version", ApiController, :version
    get "/api/stories/:id/pack", ApiController, :story_pack
  end

  scope "/", StorytimeWeb do
    get "/", PageController, :index
  end
end
