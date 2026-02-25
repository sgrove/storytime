defmodule Storytime.Stories do
  @moduledoc """
  Story domain context.

  This currently provides minimal persisted CRUD helpers used for early channel
  and API verification. Additional business rules from the spec will be layered
  in incrementally.
  """

  import Ecto.Query, warn: false

  alias Storytime.Repo
  alias Storytime.Stories.{Character, Page, Story}

  def create_story(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_slug_if_missing()

    %Story{}
    |> Story.changeset(attrs)
    |> Repo.insert()
  end

  def list_stories do
    Repo.all(from s in Story, order_by: [desc: s.inserted_at], limit: 50)
  end

  def get_story!(id), do: Repo.get!(Story, id)

  def add_character(attrs) do
    %Character{}
    |> Character.changeset(normalize_keys(attrs))
    |> Repo.insert()
  end

  def add_page(attrs) do
    %Page{}
    |> Page.changeset(normalize_keys(attrs))
    |> Repo.insert()
  end

  defp put_slug_if_missing(%{slug: slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp put_slug_if_missing(attrs) do
    title = Map.get(attrs, :title, "story")
    Map.put(attrs, :slug, slugify(title))
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "story"
      slug -> slug
    end
  end

  defp normalize_keys(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case normalize_key(k) do
        nil -> acc
        key -> Map.put(acc, key, v)
      end
    end)
  end

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    case k do
      "id" -> :id
      "title" -> :title
      "slug" -> :slug
      "art_style" -> :art_style
      "status" -> :status
      "deploy_url" -> :deploy_url
      "render_site_id" -> :render_site_id
      "story_id" -> :story_id
      "name" -> :name
      "visual_description" -> :visual_description
      "voice_provider" -> :voice_provider
      "voice_id" -> :voice_id
      "voice_model_id" -> :voice_model_id
      "headshot_url" -> :headshot_url
      "sort_order" -> :sort_order
      "page_index" -> :page_index
      "scene_description" -> :scene_description
      "narration_text" -> :narration_text
      "scene_image_url" -> :scene_image_url
      "narration_audio_url" -> :narration_audio_url
      "narration_timings_url" -> :narration_timings_url
      _ -> nil
    end
  end
end
