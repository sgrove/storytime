defmodule StorytimeWeb.EndpointCorsTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  @endpoint StorytimeWeb.Endpoint

  test "health without origin does not crash and responds" do
    conn =
      conn(:get, "/health")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status in [200, 503]
  end

  test "allowed render origin receives allow-origin header" do
    origin = "https://storytime-reader-092117.onrender.com"

    conn =
      conn(:get, "/health")
      |> put_req_header("origin", origin)
      |> @endpoint.call(@endpoint.init([]))

    assert get_resp_header(conn, "access-control-allow-origin") == [origin]
  end

  test "disallowed origin does not receive allow-origin header" do
    conn =
      conn(:get, "/health")
      |> put_req_header("origin", "https://evil.example.com")
      |> @endpoint.call(@endpoint.init([]))

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
