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

    # Health should gate traffic only on API ability to serve requests.
    # Asset disk and optional env vars are surfaced as warnings.
    ok? = checks.db.ok

    conn
    |> put_status(if(ok?, do: :ok, else: :service_unavailable))
    |> json(%{
      status: if(ok?, do: "ok", else: "degraded"),
      checks: checks,
      warnings: health_warnings(checks)
    })
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

  defp health_warnings(checks) do
    warnings = []
    warnings = if checks.assets_disk.ok, do: warnings, else: ["assets_disk_unwritable" | warnings]
    warnings = if checks.env.ok, do: warnings, else: ["missing_optional_runtime_env"]
    warnings
  end

  defp assets_base_path do
    System.get_env("ASSETS_ROOT") || "/app/assets"
  end
end
