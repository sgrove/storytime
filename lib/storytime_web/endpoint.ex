defmodule StorytimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :storytime

  @assets_root System.get_env("ASSETS_ROOT") || "/app/assets"

  socket "/socket", StorytimeWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false

  plug Plug.Static,
    at: "/assets",
    from: @assets_root,
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CORSPlug,
    origin: ["*"],
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    headers: ["*"]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug StorytimeWeb.Router
end
