defmodule Storytime.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [{Phoenix.PubSub, name: Storytime.PubSub}] ++
        maybe_repo_children([]) ++
        [StorytimeWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Storytime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    StorytimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_repo_children(children) do
    if System.get_env("DATABASE_URL") do
      children ++ [Storytime.Repo, {Oban, Application.fetch_env!(:storytime, Oban)}]
    else
      children
    end
  end
end
