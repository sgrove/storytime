defmodule Storytime.StoryPack do
  @moduledoc """
  StoryPack assembly from persisted story records.
  """

  alias Storytime.Stories

  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def build(story_id, opts \\ []) do
    case Stories.load_story_graph(story_id) do
      nil ->
        {:error, :not_found}

      story ->
        base_url = Keyword.get(opts, :base_url, endpoint_base_url())

        {:ok,
         %{
           "schemaVersion" => 1,
           "id" => story.id,
           "slug" => story.slug,
           "title" => story.title,
           "artStyle" => story.art_style,
           "status" => to_string(story.status),
           "deployUrl" => story.deploy_url,
           "characters" => build_characters(story.characters, base_url),
           "pages" => build_pages(story.pages, story.characters, base_url),
           "music" => build_music(story.music_tracks, base_url),
           "generationJobs" => build_jobs(story.generation_jobs)
         }}
    end
  end

  defp build_characters(characters, base_url) do
    characters
    |> Enum.sort_by(&{&1.sort_order || 0, &1.inserted_at || ~U[1970-01-01 00:00:00Z]})
    |> Enum.map(fn character ->
      %{
        "id" => character.id,
        "name" => character.name,
        "visualDescription" => character.visual_description,
        "voice" => %{
          "provider" => character.voice_provider,
          "voiceId" => character.voice_id,
          "modelId" => character.voice_model_id
        },
        "headshotUrl" => absolute_url(character.headshot_url, base_url),
        "sortOrder" => character.sort_order || 0
      }
    end)
  end

  defp build_pages(pages, characters, base_url) do
    character_name_by_id = Map.new(characters, &{&1.id, &1.name})

    pages
    |> Enum.sort_by(&{&1.page_index || 0, &1.sort_order || 0})
    |> Enum.map(fn page ->
      dialogue =
        page.dialogue_lines
        |> Enum.sort_by(&{&1.sort_order || 0, &1.inserted_at || ~U[1970-01-01 00:00:00Z]})
        |> Enum.map(fn line ->
          %{
            "id" => line.id,
            "characterId" => line.character_id,
            "characterName" => Map.get(character_name_by_id, line.character_id),
            "text" => line.text,
            "audioUrl" => absolute_url(line.audio_url, base_url),
            "timingsUrl" => absolute_url(line.timings_url, base_url),
            "sortOrder" => line.sort_order || 0
          }
        end)

      %{
        "id" => page.id,
        "pageIndex" => page.page_index,
        "sortOrder" => page.sort_order || page.page_index || 0,
        "sceneDescription" => page.scene_description,
        "scene" => %{
          "kind" => "scene",
          "width" => 1536,
          "height" => 1024,
          "url" => absolute_url(page.scene_image_url, base_url),
          "alt" => page.scene_description || "Scene image"
        },
        "narration" => %{
          "text" => page.narration_text,
          "audioUrl" => absolute_url(page.narration_audio_url, base_url),
          "timingsUrl" => absolute_url(page.narration_timings_url, base_url)
        },
        "dialogue" => dialogue
      }
    end)
  end

  defp build_music(tracks, base_url) do
    sorted_tracks = Enum.sort_by(tracks, &{&1.inserted_at || ~U[1970-01-01 00:00:00Z]})

    %{
      "tracks" =>
        Enum.map(sorted_tracks, fn track ->
          %{
            "id" => track.id,
            "title" => track.title,
            "mood" => track.mood,
            "audioUrl" => absolute_url(track.audio_url, base_url)
          }
        end),
      "spans" =>
        Enum.flat_map(sorted_tracks, fn track ->
          (track.music_spans || [])
          |> Enum.sort_by(&{&1.start_page_index || 0, &1.end_page_index || 0})
          |> Enum.map(fn span ->
            %{
              "id" => span.id,
              "trackId" => span.track_id,
              "startPageIndex" => span.start_page_index,
              "endPageIndex" => span.end_page_index,
              "loop" => span.loop
            }
          end)
        end)
    }
  end

  defp build_jobs(jobs) do
    jobs
    |> Enum.sort_by(&{&1.inserted_at || ~U[1970-01-01 00:00:00Z]}, :desc)
    |> Enum.take(100)
    |> Enum.map(fn job ->
      %{
        "id" => job.id,
        "jobType" => to_string(job.job_type),
        "targetId" => job.target_id,
        "status" => to_string(job.status),
        "error" => job.error,
        "insertedAt" => job.inserted_at,
        "updatedAt" => job.updated_at
      }
    end)
  end

  defp absolute_url(nil, _base_url), do: nil

  defp absolute_url(url, base_url) when is_binary(url) do
    cond do
      url == "" ->
        nil

      String.starts_with?(url, "https://") or String.starts_with?(url, "http://") ->
        url

      String.starts_with?(url, "/") ->
        base_url <> url

      true ->
        base_url <> "/" <> String.trim_leading(url, "/")
    end
  end

  defp endpoint_base_url do
    endpoint_url = StorytimeWeb.Endpoint.url() |> URI.parse()

    "#{endpoint_url.scheme}://#{endpoint_url.host}#{port_suffix(endpoint_url.port)}"
  end

  defp port_suffix(nil), do: ""
  defp port_suffix(80), do: ""
  defp port_suffix(443), do: ""
  defp port_suffix(port), do: ":#{port}"
end
