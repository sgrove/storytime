import Config

if config_env() == :prod do
  port = String.to_integer(System.get_env("PORT") || "4000")
  host = System.get_env("PHX_HOST") || "localhost"

  config :storytime, StorytimeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("b", 64),
    check_origin: false,
    server: true

  database_url = System.get_env("DATABASE_URL")

  if database_url do
    config :storytime, Storytime.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      ssl: true,
      ssl_opts: [verify: :verify_none]
  end
end
