defmodule StorytimeWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :storytime

  @assets_root System.get_env("ASSETS_ROOT") || "/app/assets"

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
    origin: &__MODULE__.allowed_origin?/1,
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

  def allowed_origin?(origin) when is_binary(origin) do
    Regex.match?(~r/^https?:\/\/localhost(:\d+)?$/, origin) or
      Regex.match?(~r/^https?:\/\/127\.0\.0\.1(:\d+)?$/, origin) or
      Regex.match?(~r/^https:\/\/[a-z0-9-]+\.onrender\.com$/, origin)
  end

  def allowed_origin?(_origin), do: false
end
