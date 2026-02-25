defmodule StorytimeWeb.HealthController do
  use StorytimeWeb, :controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
