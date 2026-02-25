defmodule StorytimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :storytime

  @assets_root System.get_env("ASSETS_ROOT") || "/app/assets"
  @cors_origins [
    ~r/^https?:\/\/localhost(:\d+)?$/,
    ~r/^https?:\/\/127\.0\.0\.1(:\d+)?$/,
    ~r/^https:\/\/[a-z0-9-]+\.onrender\.com$/
  ]

  socket("/socket", StorytimeWeb.UserSocket,
    websocket: [check_origin: false],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/assets",
    from: @assets_root,
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(CORSPlug,
    origin: @cors_origins,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    headers: ["accept", "authorization", "content-type", "origin", "user-agent"],
    expose: ["content-type"]
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(StorytimeWeb.Router)
end
