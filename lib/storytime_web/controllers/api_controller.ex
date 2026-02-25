defmodule StorytimeWeb.ApiController do
  use StorytimeWeb, :controller

  alias Storytime.Assets
  alias Storytime.Stories
  alias Storytime.JobDiagnostics
  alias Storytime.StoryPack

  @elevenlabs_tts_base "https://api.elevenlabs.io/v1/text-to-speech"

  def version(conn, _params) do
    json(conn, %{
      service: "storytime-api",
      phase: "e2e-increment",
      commit: current_commit(),
      render_service_id: System.get_env("RENDER_SERVICE_ID"),
      render_instance_id: System.get_env("RENDER_INSTANCE_ID")
    })
  end

  def stories(conn, _params) do
    with_repo(conn, fn conn ->
      payload =
        Stories.list_stories()
        |> Enum.map(&story_json/1)

      json(conn, %{stories: payload})
    end)
  end

  def show_story(conn, %{"id" => id}) do
    with_repo(conn, fn conn ->
      case Stories.load_story_graph(id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found"})

        story ->
          json(conn, %{story: story_full_json(story)})
      end
    end)
  end

  def create_story(conn, params) do
    with_repo(conn, fn conn ->
      attrs = %{
        title: Map.get(params, "title", "Untitled Story"),
        art_style: Map.get(params, "art_style", "storybook watercolor"),
        slug: Map.get(params, "slug")
      }

      case Stories.create_story(attrs) do
        {:ok, story} ->
          conn
          |> put_status(:created)
          |> json(%{story: story_json(story)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "validation_failed", details: format_errors(changeset)})
      end
    end)
  end

  def story_jobs(conn, %{"id" => id}) do
    with_repo(conn, fn conn ->
      jobs =
        JobDiagnostics.enrich(
          Stories.list_story_generation_jobs(id),
          Stories.load_story_graph(id),
          Stories.list_story_oban_jobs(id)
        )

      json(conn, %{jobs: jobs})
    end)
  end

  def story_pack(conn, %{"id" => id}) do
    with_repo(conn, fn conn ->
      case StoryPack.build(id) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found"})
      end
    end)
  end

  def story_pack_by_slug(conn, %{"slug" => slug}) do
    with_repo(conn, fn conn ->
      case Stories.get_story_by_slug(slug) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "not_found"})

        story ->
          case StoryPack.build(story.id) do
            {:ok, payload} ->
              json(conn, payload)

            {:error, :not_found} ->
              conn
              |> put_status(:not_found)
              |> json(%{error: "not_found"})
          end
      end
    end)
  end

  def voices(conn, %{"provider" => "elevenlabs"}) do
    case elevenlabs_voices() do
      {:ok, voices} ->
        json(conn, %{provider: "elevenlabs", voices: voices})

      {:error, :missing_elevenlabs_api_key} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "missing_elevenlabs_api_key"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "voice_provider_error", details: inspect(reason)})
    end
  end

  def voices(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "unsupported_voice_provider"})
  end

  def voice_preview(conn, params) do
    provider = Map.get(params, "provider", "elevenlabs")
    text = Map.get(params, "text", "") |> to_string() |> String.trim()
    voice_id = optional_id(Map.get(params, "voice_id"))
    model_id = Map.get(params, "model_id")
    story_id = optional_id(Map.get(params, "story_id"))
    character_id = optional_id(Map.get(params, "character_id"))

    cond do
      provider != "elevenlabs" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "unsupported_voice_provider"})

      is_nil(voice_id) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "missing_voice_id"})

      text == "" ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "missing_preview_text"})

      xor_present?(story_id, character_id) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "story_id_and_character_id_must_be_provided_together"})

      true ->
        with {:ok, voices} <- elevenlabs_voices(),
             true <- Enum.any?(voices, &(&1.id == voice_id)),
             {:ok, audio_bytes, audio_b64} <- elevenlabs_preview_audio(voice_id, text, model_id),
             {:ok, persisted_url} <-
               maybe_persist_voice_preview(story_id, character_id, audio_bytes) do
          json(conn, %{
            provider: "elevenlabs",
            voice_id: voice_id,
            model_id: model_id || "eleven_multilingual_v2",
            text: text,
            audio_url: persisted_url,
            audio_data_url: "data:audio/mpeg;base64,#{audio_b64}"
          })
        else
          false ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "invalid_voice_id"})

          {:error, :character_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "character_not_found"})

          {:error, :database_unavailable} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "database_unavailable"})

          {:error, :missing_elevenlabs_api_key} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "missing_elevenlabs_api_key"})

          {:error, reason} ->
            conn
            |> put_status(:bad_gateway)
            |> json(%{error: "voice_preview_failed", details: inspect(reason)})
        end
    end
  end

  defp with_repo(conn, fun) do
    if Stories.repo_running?() do
      fun.(conn)
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "database_unavailable"})
    end
  end

  defp story_json(story) do
    %{
      id: story.id,
      title: story.title,
      slug: story.slug,
      art_style: story.art_style,
      status: to_string(story.status),
      deploy_url: story.deploy_url,
      render_site_id: story.render_site_id
    }
  end

  defp story_full_json(story) do
    %{
      id: story.id,
      title: story.title,
      slug: story.slug,
      art_style: story.art_style,
      status: to_string(story.status),
      deploy_url: story.deploy_url,
      render_site_id: story.render_site_id,
      characters:
        Enum.map(story.characters, fn c ->
          %{
            id: c.id,
            name: c.name,
            visual_description: c.visual_description,
            voice_provider: c.voice_provider,
            voice_id: c.voice_id,
            voice_model_id: c.voice_model_id,
            headshot_url: c.headshot_url,
            voice_preview_url: c.voice_preview_url,
            sort_order: c.sort_order
          }
        end),
      pages:
        Enum.map(story.pages, fn p ->
          %{
            id: p.id,
            page_index: p.page_index,
            scene_description: p.scene_description,
            narration_text: p.narration_text,
            scene_image_url: p.scene_image_url,
            narration_audio_url: p.narration_audio_url,
            narration_timings_url: p.narration_timings_url,
            sort_order: p.sort_order,
            dialogue_lines:
              Enum.map(p.dialogue_lines, fn d ->
                %{
                  id: d.id,
                  page_id: d.page_id,
                  character_id: d.character_id,
                  text: d.text,
                  audio_url: d.audio_url,
                  timings_url: d.timings_url,
                  sort_order: d.sort_order
                }
              end)
          }
        end),
      music_tracks:
        Enum.map(story.music_tracks, fn t ->
          %{
            id: t.id,
            title: t.title,
            mood: t.mood,
            audio_url: t.audio_url,
            music_spans:
              Enum.map(t.music_spans, fn s ->
                %{
                  id: s.id,
                  start_page_index: s.start_page_index,
                  end_page_index: s.end_page_index,
                  loop: s.loop
                }
              end)
          }
        end),
      generation_jobs:
        Enum.map(story.generation_jobs, fn j ->
          %{
            id: j.id,
            job_type: to_string(j.job_type),
            status: to_string(j.status),
            target_id: j.target_id,
            error: j.error
          }
        end)
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end

  defp current_commit do
    System.get_env("RENDER_GIT_COMMIT") ||
      System.get_env("RENDER_GIT_SHA") ||
      System.get_env("SOURCE_VERSION")
  end

  defp elevenlabs_voices do
    api_key = System.get_env("ELEVENLABS_API_KEY")

    if api_key in [nil, ""] do
      {:error, :missing_elevenlabs_api_key}
    else
      headers = [
        {"xi-api-key", api_key},
        {"accept", "application/json"}
      ]

      case Req.get("https://api.elevenlabs.io/v1/voices", headers: headers) do
        {:ok, %{status: 200, body: %{"voices" => voices}}} when is_list(voices) ->
          parsed =
            voices
            |> Enum.map(fn voice ->
              %{
                id: voice["voice_id"] || voice["id"],
                name: voice["name"],
                category: voice["category"],
                description: voice["description"],
                labels: voice["labels"] || %{}
              }
            end)
            |> Enum.filter(fn voice -> is_binary(voice.id) and voice.id != "" end)
            |> Enum.sort_by(fn voice -> String.downcase(voice.name || "") end)

          {:ok, parsed}

        {:ok, %{status: status, body: body}} ->
          {:error, {:elevenlabs_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp elevenlabs_preview_audio(voice_id, text, model_id) do
    api_key = System.get_env("ELEVENLABS_API_KEY")

    if api_key in [nil, ""] do
      {:error, :missing_elevenlabs_api_key}
    else
      headers = [
        {"xi-api-key", api_key},
        {"content-type", "application/json"}
      ]

      body = %{
        text: text,
        model_id: model_id || "eleven_multilingual_v2",
        output_format: "mp3_44100_128"
      }

      url = "#{@elevenlabs_tts_base}/#{voice_id}/with-timestamps"

      case Req.post(url, headers: headers, json: body) do
        {:ok, %{status: 200, body: %{"audio_base64" => audio_b64}}} when is_binary(audio_b64) ->
          case Base.decode64(audio_b64) do
            {:ok, audio_bytes} -> {:ok, audio_bytes, audio_b64}
            :error -> {:error, :invalid_audio_payload}
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:elevenlabs_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_persist_voice_preview(nil, nil, _audio_bytes), do: {:ok, nil}

  defp maybe_persist_voice_preview(story_id, character_id, audio_bytes)
       when is_binary(story_id) and story_id != "" and is_binary(character_id) and
              character_id != "" do
    if Stories.repo_running?() do
      filename = "voice_preview_#{character_id}.mp3"

      with {:ok, asset_url} <- Assets.write_binary(story_id, filename, audio_bytes),
           {:ok, _character} <-
             Stories.set_character_voice_preview(story_id, character_id, asset_url) do
        {:ok, asset_url}
      else
        {:error, :not_found} -> {:error, :character_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :database_unavailable}
    end
  end

  defp maybe_persist_voice_preview(_story_id, _character_id, _audio_bytes),
    do: {:error, :character_not_found}

  defp xor_present?(a, b), do: present?(a) != present?(b)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp optional_id(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp optional_id(_value), do: nil
end
