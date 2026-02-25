defmodule StorytimeWeb.ApiVoicesTest do
  use ExUnit.Case, async: false
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
end
