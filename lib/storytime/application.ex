defmodule Storytime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = System.get_env("PORT", "4000") |> String.to_integer()

    children = [
      {Plug.Cowboy,
       scheme: :http,
       plug: Storytime.Router,
       options: [port: port, ip: {0, 0, 0, 0}]}
    ]

    opts = [strategy: :one_for_one, name: Storytime.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
