defmodule StorytimeWeb.ApiVoicesTest do
  use ExUnit.Case, async: false
  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  @endpoint StorytimeWeb.Endpoint

  test "unsupported provider returns bad request" do
    conn =
      conn(:get, "/api/voices/unknown")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 400
    assert %{"error" => "unsupported_voice_provider"} = Jason.decode!(conn.resp_body)
  end

  test "elevenlabs provider returns unavailable when key missing" do
    previous = System.get_env("ELEVENLABS_API_KEY")
    System.delete_env("ELEVENLABS_API_KEY")

    try do
      conn =
        conn(:get, "/api/voices/elevenlabs")
        |> @endpoint.call(@endpoint.init([]))

      assert conn.status == 503
      assert %{"error" => "missing_elevenlabs_api_key"} = Jason.decode!(conn.resp_body)
    after
      if is_binary(previous), do: System.put_env("ELEVENLABS_API_KEY", previous)
    end
  end

  test "voice preview rejects unsupported provider" do
    conn =
      conn(:post, "/api/voices/preview", Jason.encode!(%{"provider" => "unknown"}))
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 400
    assert %{"error" => "unsupported_voice_provider"} = Jason.decode!(conn.resp_body)
  end

  test "voice preview requires voice_id" do
    conn =
      conn(
        :post,
        "/api/voices/preview",
        Jason.encode!(%{"provider" => "elevenlabs", "text" => "hi"})
      )
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 422
    assert %{"error" => "missing_voice_id"} = Jason.decode!(conn.resp_body)
  end

  test "voice preview requires text" do
    conn =
      conn(
        :post,
        "/api/voices/preview",
        Jason.encode!(%{"provider" => "elevenlabs", "voice_id" => "voice_123"})
      )
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 422
    assert %{"error" => "missing_preview_text"} = Jason.decode!(conn.resp_body)
  end

  test "voice preview requires story_id and character_id together when persisting" do
    conn =
      conn(
        :post,
        "/api/voices/preview",
        Jason.encode!(%{
          "provider" => "elevenlabs",
          "voice_id" => "voice_123",
          "text" => "hello there",
          "story_id" => "story-1"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status == 422

    assert %{"error" => "story_id_and_character_id_must_be_provided_together"} =
             Jason.decode!(conn.resp_body)
  end

  test "voice preview returns unavailable when key missing" do
    previous = System.get_env("ELEVENLABS_API_KEY")
    System.delete_env("ELEVENLABS_API_KEY")

    try do
      conn =
        conn(
          :post,
          "/api/voices/preview",
          Jason.encode!(%{
            "provider" => "elevenlabs",
            "voice_id" => "voice_123",
            "text" => "hello there"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> @endpoint.call(@endpoint.init([]))

      assert conn.status == 503
      assert %{"error" => "missing_elevenlabs_api_key"} = Jason.decode!(conn.resp_body)
    after
      if is_binary(previous), do: System.put_env("ELEVENLABS_API_KEY", previous)
    end
  end
end
