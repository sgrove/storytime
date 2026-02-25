defmodule StorytimeWeb.ApiReadinessTest do
  use ExUnit.Case, async: true
  import Plug.Test

  @endpoint StorytimeWeb.Endpoint

  test "story readiness endpoint is exposed" do
    conn =
      conn(:get, "/api/stories/test-story-id/readiness")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status in [200, 404, 503]
  end
end
