defmodule StorytimeWeb.ApiMusicTagsTest do
  use ExUnit.Case, async: true
  import Plug.Test

  @endpoint StorytimeWeb.Endpoint

  test "music tags endpoint returns sonauto v3 tags" do
    conn =
      conn(:get, "/api/music-tags")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 200

    %{"provider" => provider, "version" => version, "tags" => tags} =
      Jason.decode!(conn.resp_body)

    assert provider == "sonauto"
    assert version == "v3"
    assert is_list(tags)
    assert "children" in tags
    assert "instrumental" in tags
  end
end
