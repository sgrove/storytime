defmodule StorytimeWeb.HealthControllerTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  @endpoint StorytimeWeb.Endpoint

  test "health returns structured JSON checks payload" do
    conn =
      conn(:get, "/health")
      |> @endpoint.call(@endpoint.init([]))

    assert conn.status in [200, 503]
    assert ["application/json; charset=utf-8"] = get_resp_header(conn, "content-type")

    body = Jason.decode!(conn.resp_body)

    assert is_binary(body["status"])
    assert is_map(body["checks"])
    assert is_list(body["warnings"])
    assert is_map(body["checks"]["app"])
    assert is_map(body["checks"]["db"])
    assert is_map(body["checks"]["assets_disk"])
    assert is_map(body["checks"]["env"])
  end

  test "health is degraded when repo is not running in test environment" do
    conn =
      conn(:get, "/health")
      |> @endpoint.call(@endpoint.init([]))

    body = Jason.decode!(conn.resp_body)
    assert body["checks"]["db"]["ok"] == false
    assert conn.status == 503
    assert body["status"] == "degraded"
  end
end
