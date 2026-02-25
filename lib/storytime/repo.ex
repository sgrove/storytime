defmodule Storytime.Repo do
  use Ecto.Repo,
    otp_app: :storytime,
    adapter: Ecto.Adapters.Postgres
end
