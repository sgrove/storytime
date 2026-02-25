import Config

config :storytime,
  ecto_repos: [Storytime.Repo]

config :storytime, Storytime.Repo,
  migration_primary_key: [type: :binary_id],
  migration_foreign_key: [type: :binary_id]

config :storytime, Oban,
  repo: Storytime.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24}],
  queues: [generation: 20, deploy: 5]

config :storytime, StorytimeWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: StorytimeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Storytime.PubSub,
  secret_key_base: String.duplicate("a", 64),
  server: true,
  check_origin: false

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
