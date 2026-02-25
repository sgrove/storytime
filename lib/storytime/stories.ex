defmodule Storytime.Stories do
  @moduledoc """
  Story domain context.

  This module owns authoritative persistence for editor mutations and generation
  job tracking.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Storytime.Repo

  alias Storytime.Stories.{
    Character,
    DialogueLine,
    GenerationJob,
    MusicSpan,
    MusicTrack,
    Page,
    Story
  }

  @type job_type :: :headshot | :scene | :dialogue_tts | :narration_tts | :music | :deploy

  def repo_running?, do: Process.whereis(Storytime.Repo) != nil

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
    Repo.all(from s in Story, order_by: [desc: s.inserted_at], limit: 100)
  end

  def get_story(id), do: Repo.get(Story, id)

  def get_story!(id), do: Repo.get!(Story, id)

  def get_story_by_slug(slug), do: Repo.get_by(Story, slug: slug)

  def update_story(story_id, attrs) do
    story_id
    |> get_story!()
    |> Story.changeset(normalize_keys(attrs))
    |> Repo.update()
  end

  def load_story_graph(story_id) do
    story_id
    |> get_story()
    |> maybe_preload_story_graph()
  end

  def list_story_generation_jobs(story_id) do
    Repo.all(
      from j in GenerationJob,
        where: j.story_id == ^story_id,
        order_by: [desc: j.inserted_at],
        limit: 200
    )
  end

  def create_character(story_id, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put(:story_id, story_id)
      |> Map.put_new(:sort_order, next_character_sort(story_id))
      |> Map.put_new(:voice_provider, "elevenlabs")

    %Character{}
    |> Character.changeset(attrs)
    |> Repo.insert()
  end

  def update_character(story_id, character_id, attrs) do
    with %Character{} = character <- get_story_character(story_id, character_id) do
      character
      |> Character.changeset(normalize_keys(attrs))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_character(story_id, character_id) do
    with %Character{} = character <- get_story_character(story_id, character_id) do
      Repo.delete(character)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_characters(story_id) do
    Repo.all(
      from c in Character,
        where: c.story_id == ^story_id,
        order_by: [asc: c.sort_order, asc: c.inserted_at]
    )
  end

  def create_page(story_id, attrs) do
    attrs = normalize_keys(attrs)

    next_index = next_page_index(story_id)

    attrs =
      attrs
      |> Map.put(:story_id, story_id)
      |> Map.put_new(:page_index, next_index)
      |> Map.put_new(:sort_order, next_index)
      |> Map.put_new(:scene_description, "")
      |> Map.put_new(:narration_text, "")

    %Page{}
    |> Page.changeset(attrs)
    |> Repo.insert()
  end

  def update_page(story_id, page_id, attrs) do
    with %Page{} = page <- get_story_page(story_id, page_id) do
      page
      |> Page.changeset(normalize_keys(attrs))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_page(story_id, page_id) do
    with %Page{} = page <- get_story_page(story_id, page_id) do
      Repo.delete(page)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_pages(story_id) do
    Repo.all(
      from p in Page,
        where: p.story_id == ^story_id,
        order_by: [asc: p.page_index, asc: p.sort_order, asc: p.inserted_at]
    )
  end

  def reorder_pages(story_id, requested_ids) when is_list(requested_ids) do
    existing_pages = list_pages(story_id)
    existing_ids = Enum.map(existing_pages, & &1.id)

    ordered_ids =
      requested_ids
      |> Enum.uniq()
      |> Enum.filter(&(&1 in existing_ids))

    tail_ids = existing_ids -- ordered_ids
    final_ids = ordered_ids ++ tail_ids

    multi =
      Enum.with_index(final_ids)
      |> Enum.reduce(
        Multi.new()
        |> Multi.run(:validate, fn _repo, _changes ->
          if final_ids == [] and existing_ids != [] do
            {:error, :invalid_page_order}
          else
            {:ok, :valid}
          end
        end),
        fn {page_id, idx}, m ->
          Multi.update_all(
            m,
            {:page, page_id},
            from(p in Page, where: p.story_id == ^story_id and p.id == ^page_id),
            set: [page_index: idx, sort_order: idx]
          )
        end
      )

    multi
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, list_pages(story_id)}
      {:error, _op, reason, _changes} -> {:error, reason}
    end
  end

  def add_dialogue_line(story_id, attrs) do
    attrs = normalize_keys(attrs)

    with %Page{} <- get_story_page(story_id, Map.get(attrs, :page_id)),
         %Character{} <- get_story_character(story_id, Map.get(attrs, :character_id)) do
      attrs =
        attrs
        |> Map.put_new(:sort_order, next_dialogue_sort(Map.fetch!(attrs, :page_id)))
        |> Map.put_new(:text, "")

      %DialogueLine{}
      |> DialogueLine.changeset(attrs)
      |> Repo.insert()
    else
      _ -> {:error, :not_found}
    end
  end

  def update_dialogue_line(story_id, line_id, attrs) do
    with %DialogueLine{} = line <- get_story_dialogue_line(story_id, line_id) do
      line
      |> DialogueLine.changeset(normalize_keys(attrs))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_dialogue_line(story_id, line_id) do
    with %DialogueLine{} = line <- get_story_dialogue_line(story_id, line_id) do
      Repo.delete(line)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_dialogue_lines(story_id) do
    Repo.all(
      from d in DialogueLine,
        join: p in Page,
        on: p.id == d.page_id,
        where: p.story_id == ^story_id,
        order_by: [asc: p.page_index, asc: d.sort_order, asc: d.inserted_at],
        preload: [:character]
    )
  end

  def create_music_track(story_id, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put(:story_id, story_id)
      |> Map.put_new(:title, "Music Track")
      |> Map.put_new(:mood, "gentle")

    %MusicTrack{}
    |> MusicTrack.changeset(attrs)
    |> Repo.insert()
  end

  def update_music_track(story_id, track_id, attrs) do
    with %MusicTrack{} = track <- get_story_music_track(story_id, track_id) do
      track
      |> MusicTrack.changeset(normalize_keys(attrs))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_music_track(story_id, track_id) do
    with %MusicTrack{} = track <- get_story_music_track(story_id, track_id) do
      Repo.delete(track)
    else
      nil -> {:error, :not_found}
    end
  end

  def list_music_tracks(story_id) do
    Repo.all(
      from t in MusicTrack,
        where: t.story_id == ^story_id,
        order_by: [asc: t.inserted_at],
        preload: [:music_spans]
    )
  end

  def create_music_span(story_id, track_id, attrs) do
    attrs = normalize_keys(attrs)

    with %MusicTrack{} <- get_story_music_track(story_id, track_id) do
      attrs = attrs |> Map.put(:track_id, track_id) |> Map.put_new(:loop, true)

      %MusicSpan{}
      |> MusicSpan.changeset(attrs)
      |> Repo.insert()
    else
      _ -> {:error, :not_found}
    end
  end

  def update_music_span(story_id, span_id, attrs) do
    with %MusicSpan{} = span <- get_story_music_span(story_id, span_id) do
      span
      |> MusicSpan.changeset(normalize_keys(attrs))
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def delete_music_span(story_id, span_id) do
    with %MusicSpan{} = span <- get_story_music_span(story_id, span_id) do
      Repo.delete(span)
    else
      nil -> {:error, :not_found}
    end
  end

  def create_generation_job(story_id, job_type, target_id \\ nil, attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put(:story_id, story_id)
      |> Map.put(:job_type, job_type)
      |> Map.put(:target_id, target_id)
      |> Map.put_new(:status, :pending)

    %GenerationJob{}
    |> GenerationJob.changeset(attrs)
    |> Repo.insert()
  end

  def set_generation_job_status(job_id, status, error \\ nil) do
    with %GenerationJob{} = job <- Repo.get(GenerationJob, job_id) do
      attrs = %{status: status, error: error}

      job
      |> GenerationJob.changeset(attrs)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def set_story_status(story_id, status) do
    with %Story{} = story <- get_story(story_id) do
      story
      |> Story.changeset(%{status: status})
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def mark_story_deployed(story_id, render_site_id, deploy_url) do
    with %Story{} = story <- get_story(story_id) do
      story
      |> Story.changeset(%{
        status: :deployed,
        render_site_id: render_site_id,
        deploy_url: deploy_url
      })
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def set_character_headshot(story_id, character_id, headshot_url) do
    update_character(story_id, character_id, %{headshot_url: headshot_url})
  end

  def set_page_scene(story_id, page_id, scene_image_url) do
    update_page(story_id, page_id, %{scene_image_url: scene_image_url})
  end

  def set_page_narration(story_id, page_id, narration_audio_url, narration_timings_url) do
    update_page(story_id, page_id, %{
      narration_audio_url: narration_audio_url,
      narration_timings_url: narration_timings_url
    })
  end

  def set_dialogue_audio(story_id, line_id, audio_url, timings_url) do
    update_dialogue_line(story_id, line_id, %{audio_url: audio_url, timings_url: timings_url})
  end

  def set_music_audio(story_id, track_id, audio_url) do
    update_music_track(story_id, track_id, %{audio_url: audio_url})
  end

  defp maybe_preload_story_graph(nil), do: nil

  defp maybe_preload_story_graph(%Story{} = story) do
    Repo.preload(story, [
      :generation_jobs,
      :characters,
      pages: [:dialogue_lines],
      music_tracks: [:music_spans]
    ])
  end

  defp get_story_character(story_id, character_id) do
    Repo.one(
      from c in Character,
        where: c.story_id == ^story_id and c.id == ^character_id
    )
  end

  defp get_story_page(story_id, page_id) do
    Repo.one(
      from p in Page,
        where: p.story_id == ^story_id and p.id == ^page_id
    )
  end

  defp get_story_dialogue_line(story_id, line_id) do
    Repo.one(
      from d in DialogueLine,
        join: p in Page,
        on: p.id == d.page_id,
        where: p.story_id == ^story_id and d.id == ^line_id
    )
  end

  defp get_story_music_track(story_id, track_id) do
    Repo.one(
      from t in MusicTrack,
        where: t.story_id == ^story_id and t.id == ^track_id
    )
  end

  defp get_story_music_span(story_id, span_id) do
    Repo.one(
      from s in MusicSpan,
        join: t in MusicTrack,
        on: s.track_id == t.id,
        where: t.story_id == ^story_id and s.id == ^span_id
    )
  end

  defp next_character_sort(story_id) do
    (Repo.one(from c in Character, where: c.story_id == ^story_id, select: max(c.sort_order)) || -1) + 1
  end

  defp next_page_index(story_id) do
    (Repo.one(from p in Page, where: p.story_id == ^story_id, select: max(p.page_index)) || -1) + 1
  end

  defp next_dialogue_sort(page_id) do
    (Repo.one(from d in DialogueLine, where: d.page_id == ^page_id, select: max(d.sort_order)) || -1) + 1
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

  defp normalize_keys(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      case normalize_key(k) do
        nil -> acc
        key -> Map.put(acc, key, v)
      end
    end)
  end

  defp normalize_keys(_), do: %{}

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
      "page_id" -> :page_id
      "page_index" -> :page_index
      "scene_description" -> :scene_description
      "narration_text" -> :narration_text
      "scene_image_url" -> :scene_image_url
      "narration_audio_url" -> :narration_audio_url
      "narration_timings_url" -> :narration_timings_url
      "character_id" -> :character_id
      "text" -> :text
      "audio_url" -> :audio_url
      "timings_url" -> :timings_url
      "mood" -> :mood
      "track_id" -> :track_id
      "start_page_index" -> :start_page_index
      "end_page_index" -> :end_page_index
      "loop" -> :loop
      "job_type" -> :job_type
      "target_id" -> :target_id
      "error" -> :error
      _ -> nil
    end
  end
end
