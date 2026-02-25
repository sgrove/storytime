defmodule Storytime.SonautoTags do
  @moduledoc """
  Provides the official Sonauto v3 tags sourced from the public tag explorer.
  """

  @cache_key {__MODULE__, :all}
  @lookup_cache_key {__MODULE__, :lookup}

  @tags_path Application.app_dir(:storytime, "priv/sonauto_v3_tags.txt")

  @spec all() :: [String.t()]
  def all do
    case :persistent_term.get(@cache_key, :unset) do
      :unset ->
        tags = load_tags()
        :persistent_term.put(@cache_key, tags)
        tags

      tags when is_list(tags) ->
        tags
    end
  end

  @spec normalize_tags([String.t()] | String.t() | nil) :: [String.t()]
  def normalize_tags(nil), do: []

  def normalize_tags(raw) when is_binary(raw) do
    raw
    |> split_raw_tags()
    |> normalize_tags()
  end

  def normalize_tags(raw) when is_list(raw) do
    lookup = tag_lookup()

    raw
    |> Enum.map(&normalize_tag_token/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Map.get(lookup, String.downcase(&1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec contains?(String.t() | nil) :: boolean()
  def contains?(tag) when is_binary(tag) do
    Map.has_key?(tag_lookup(), String.downcase(String.trim(tag)))
  end

  def contains?(_), do: false

  defp tag_lookup do
    case :persistent_term.get(@lookup_cache_key, :unset) do
      :unset ->
        lookup =
          all()
          |> Map.new(fn tag -> {String.downcase(tag), tag} end)

        :persistent_term.put(@lookup_cache_key, lookup)
        lookup

      lookup when is_map(lookup) ->
        lookup
    end
  end

  defp load_tags do
    with {:ok, content} <- File.read(@tags_path) do
      content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.uniq()
    else
      _ -> []
    end
  end

  defp split_raw_tags(raw) do
    raw
    |> String.split(~r/[,;\n]/u, trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_tag_token(token) when is_binary(token), do: String.trim(token)
  defp normalize_tag_token(token), do: token |> to_string() |> String.trim()
end
