defmodule StorytimeWeb.ApiController do
  use StorytimeWeb, :controller

  def version(conn, _params) do
    json(conn, %{service: "storytime-api", phase: "phoenix-skeleton"})
  end

  def story_pack(conn, %{"id" => id}) do
    payload = Storytime.StoryPack.build(id)
    json(conn, payload)
  end
end
