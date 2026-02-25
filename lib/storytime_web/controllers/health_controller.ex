defmodule StorytimeWeb.HealthController do
  use StorytimeWeb, :controller

  alias Storytime.Repo
  alias Storytime.Stories

  @required_envs [
    "SECRET_KEY_BASE",
    "DATABASE_URL",
    "OPENAI_API_KEY",
    "ELEVENLABS_API_KEY",
    "SONAUTO_API_KEY",
    "RENDER_API_KEY"
  ]

  def show(conn, _params) do
    checks = %{
      app: %{ok: true},
      db: db_check(),
      assets_disk: assets_disk_check(),
      env: env_check()
    }

    ok? = Enum.all?(checks, fn {_k, v} -> v.ok end)

    conn
    |> put_status(if(ok?, do: :ok, else: :service_unavailable))
    |> json(%{status: if(ok?, do: "ok", else: "degraded"), checks: checks})
  end

  defp db_check do
    cond do
      not Stories.repo_running?() ->
        %{ok: false, reason: "repo_not_started"}

      true ->
        case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
          {:ok, _} -> %{ok: true}
          {:error, reason} -> %{ok: false, reason: Exception.message(reason)}
        end
    end
  rescue
    err -> %{ok: false, reason: Exception.message(err)}
  end

  defp assets_disk_check do
    base = assets_base_path()

    case File.mkdir_p(base) do
      :ok -> %{ok: true, path: base}
      {:error, reason} -> %{ok: false, path: base, reason: inspect(reason)}
    end
  end

  defp env_check do
    missing = Enum.filter(@required_envs, &(System.get_env(&1) in [nil, ""]))

    if missing == [] do
      %{ok: true}
    else
      %{ok: false, missing: missing}
    end
  end

  defp assets_base_path do
    System.get_env("ASSETS_ROOT") || "/app/assets"
  end
end
