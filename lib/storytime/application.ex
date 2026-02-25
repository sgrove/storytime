defmodule Storytime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Storytime.PubSub,
        StorytimeWeb.Endpoint
      ]
      |> maybe_add_repo()

    opts = [strategy: :one_for_one, name: Storytime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    StorytimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_add_repo(children) do
    if System.get_env("DATABASE_URL") do
      [Storytime.Repo | children]
    else
      children
    end
  end
end
