defmodule Storytime.Assets do
  @moduledoc """
  Helpers for deterministic asset pathing under Render persistent disk.
  """

  @spec root_path() :: String.t()
  def root_path do
    System.get_env("ASSETS_ROOT") || "/app/assets"
  end

  @spec story_dir(String.t()) :: String.t()
  def story_dir(story_id), do: Path.join(root_path(), story_id)

  @spec ensure_story_dir(String.t()) :: :ok | {:error, term()}
  def ensure_story_dir(story_id) do
    story_dir(story_id)
    |> File.mkdir_p()
  end

  @spec write_binary(String.t(), String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def write_binary(story_id, filename, bytes) when is_binary(bytes) do
    cache_bust = Integer.to_string(System.system_time(:millisecond))

    with :ok <- ensure_story_dir(story_id),
         :ok <- File.write(Path.join(story_dir(story_id), filename), bytes) do
      {:ok, public_path(story_id, filename, cache_bust)}
    end
  end

  @spec write_json(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def write_json(story_id, filename, payload) when is_map(payload) do
    with {:ok, encoded} <- Jason.encode(payload),
         {:ok, url} <- write_binary(story_id, filename, encoded <> "\n") do
      {:ok, url}
    end
  end

  @spec public_path(String.t(), String.t()) :: String.t()
  def public_path(story_id, filename), do: "/assets/#{story_id}/#{filename}"

  @spec public_path(String.t(), String.t(), String.t() | nil) :: String.t()
  def public_path(story_id, filename, cache_bust)
      when is_binary(cache_bust) and cache_bust != "" do
    public_path(story_id, filename) <> "?v=" <> URI.encode_www_form(cache_bust)
  end

  def public_path(story_id, filename, _cache_bust), do: public_path(story_id, filename)

  @spec tiny_png() :: binary()
  def tiny_png do
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO3Zl7cAAAAASUVORK5CYII="
    |> Base.decode64!()
  end
end
