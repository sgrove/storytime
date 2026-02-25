defmodule StorytimeWeb.StoryChannel do
  use StorytimeWeb, :channel

  alias Storytime.Generation
  alias Storytime.Stories

  @required_client_events [
    "update_story",
    "add_character",
    "update_character",
    "delete_character",
    "add_page",
    "update_page",
    "reorder_pages",
    "delete_page",
    "add_dialogue_line",
    "update_dialogue_line",
    "delete_dialogue_line",
    "generate_headshot",
    "generate_scene",
    "generate_all_scenes",
    "generate_dialogue",
    "generate_all_dialogue",
    "generate_dialogue_audio",
    "generate_all_audio",
    "generate_music",
    "retry_generation",
    "generate_all",
    "deploy_story"
  ]

  @required_broadcast_events [
    "story_updated",
    "character_added",
    "page_updated",
    "generation_started",
    "generation_progress",
    "generation_completed",
    "generation_failed",
    "deploy_started",
    "deploy_completed",
    "deploy_failed"
  ]

  @required_broadcast_payload_keys %{
    "story_updated" => ["story"],
    "character_added" => ["character"],
    "page_updated" => ["page"],
    "generation_started" => ["job_type", "target_id"],
    "generation_progress" => ["job_type", "target_id", "progress"],
    "generation_completed" => ["job_type", "target_id"],
    "generation_failed" => ["job_type", "target_id", "error"],
    "deploy_started" => [],
    "deploy_completed" => ["url"],
    "deploy_failed" => ["error"]
  }

  @channel_broadcast_payload_keys %{
    "story_updated" => ["story"],
    "character_added" => ["character"],
    "character_updated" => ["character"],
    "character_deleted" => ["id", "character"],
    "page_added" => ["page"],
    "page_updated" => ["page"],
    "page_deleted" => ["id", "page"],
    "pages_reordered" => ["pages"],
    "dialogue_line_added" => ["line"],
    "dialogue_line_updated" => ["line"],
    "dialogue_line_deleted" => ["id", "line"],
    "music_track_added" => ["track"],
    "music_track_updated" => ["track"],
    "music_track_deleted" => ["id", "track"],
    "music_span_added" => ["span"],
    "music_span_updated" => ["span"],
    "music_span_deleted" => ["id", "span"],
    "generation_started" => ["story_id", "job_type", "target_id", "job_id"],
    "deploy_started" => ["story_id", "job_id"]
  }

  def required_client_events, do: @required_client_events
  def required_broadcast_events, do: @required_broadcast_events
  def required_broadcast_payload_keys, do: @required_broadcast_payload_keys
  def channel_broadcast_payload_keys, do: @channel_broadcast_payload_keys

  @impl true
  def join("story:" <> story_id, _payload, socket) do
    if Stories.repo_running?() do
      case Stories.get_story(story_id) do
        nil -> {:error, %{error: "story_not_found"}}
        _story -> {:ok, %{story_id: story_id, joined: true}, assign(socket, :story_id, story_id)}
      end
    else
      {:error, %{error: "database_unavailable"}}
    end
  end

  @impl true
  def handle_in("update_story", payload, socket) do
    with {:ok, story} <- Stories.update_story(socket.assigns.story_id, payload) do
      broadcast!(socket, "story_updated", %{story: story_payload(story)})
      {:reply, {:ok, %{story: story_payload(story)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("add_character", payload, socket) do
    with {:ok, character} <- Stories.create_character(socket.assigns.story_id, payload) do
      broadcast!(socket, "character_added", %{character: character_payload(character)})
      {:reply, {:ok, %{character: character_payload(character)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("update_character", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, character} <- Stories.update_character(socket.assigns.story_id, id, payload) do
      broadcast!(socket, "character_updated", %{character: character_payload(character)})
      {:reply, {:ok, %{character: character_payload(character)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("delete_character", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, character} <- Stories.delete_character(socket.assigns.story_id, id) do
      broadcast!(socket, "character_deleted", %{id: id, character: character_payload(character)})
      {:reply, {:ok, %{id: id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("add_page", payload, socket) do
    with {:ok, page} <- Stories.create_page(socket.assigns.story_id, payload) do
      broadcast!(socket, "page_added", %{page: page_payload(page)})
      {:reply, {:ok, %{page: page_payload(page)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("update_page", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, page} <- Stories.update_page(socket.assigns.story_id, id, payload) do
      broadcast!(socket, "page_updated", %{page: page_payload(page)})
      {:reply, {:ok, %{page: page_payload(page)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("delete_page", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, page} <- Stories.delete_page(socket.assigns.story_id, id) do
      broadcast!(socket, "page_deleted", %{id: id, page: page_payload(page)})
      {:reply, {:ok, %{id: id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("reorder_pages", %{"page_ids" => page_ids}, socket) when is_list(page_ids) do
    with {:ok, pages} <- Stories.reorder_pages(socket.assigns.story_id, page_ids) do
      payload = Enum.map(pages, &page_payload/1)
      broadcast!(socket, "pages_reordered", %{pages: payload})
      {:reply, {:ok, %{pages: payload}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  def handle_in("reorder_pages", _payload, socket) do
    {:reply, {:error, %{error: "invalid_page_order"}}, socket}
  end

  @impl true
  def handle_in("add_dialogue_line", payload, socket) do
    with {:ok, line} <- Stories.add_dialogue_line(socket.assigns.story_id, payload) do
      broadcast!(socket, "dialogue_line_added", %{line: dialogue_payload(line)})
      {:reply, {:ok, %{line: dialogue_payload(line)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("update_dialogue_line", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, line} <- Stories.update_dialogue_line(socket.assigns.story_id, id, payload) do
      broadcast!(socket, "dialogue_line_updated", %{line: dialogue_payload(line)})
      {:reply, {:ok, %{line: dialogue_payload(line)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("delete_dialogue_line", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, line} <- Stories.delete_dialogue_line(socket.assigns.story_id, id) do
      broadcast!(socket, "dialogue_line_deleted", %{id: id, line: dialogue_payload(line)})
      {:reply, {:ok, %{id: id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("add_music_track", payload, socket) do
    with {:ok, track} <- Stories.create_music_track(socket.assigns.story_id, payload) do
      broadcast!(socket, "music_track_added", %{track: music_track_payload(track)})
      {:reply, {:ok, %{track: music_track_payload(track)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("update_music_track", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, track} <- Stories.update_music_track(socket.assigns.story_id, id, payload) do
      broadcast!(socket, "music_track_updated", %{track: music_track_payload(track)})
      {:reply, {:ok, %{track: music_track_payload(track)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("delete_music_track", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, track} <- Stories.delete_music_track(socket.assigns.story_id, id) do
      broadcast!(socket, "music_track_deleted", %{id: id, track: music_track_payload(track)})
      {:reply, {:ok, %{id: id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("add_music_span", payload, socket) do
    with {:ok, track_id} <- required_field(payload, "track_id"),
         {:ok, span} <- Stories.create_music_span(socket.assigns.story_id, track_id, payload) do
      broadcast!(socket, "music_span_added", %{span: music_span_payload(span)})
      {:reply, {:ok, %{span: music_span_payload(span)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("update_music_span", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, span} <- Stories.update_music_span(socket.assigns.story_id, id, payload) do
      broadcast!(socket, "music_span_updated", %{span: music_span_payload(span)})
      {:reply, {:ok, %{span: music_span_payload(span)}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("delete_music_span", payload, socket) do
    with {:ok, id} <- required_id(payload),
         {:ok, span} <- Stories.delete_music_span(socket.assigns.story_id, id) do
      broadcast!(socket, "music_span_deleted", %{id: id, span: music_span_payload(span)})
      {:reply, {:ok, %{id: id}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("generate_headshot", payload, socket),
    do: enqueue_generation(socket, :headshot, Map.get(payload, "character_id"), payload)

  @impl true
  def handle_in("generate_scene", payload, socket),
    do: enqueue_generation(socket, :scene, Map.get(payload, "page_id"), payload)

  @impl true
  def handle_in("generate_dialogue", payload, socket),
    do: enqueue_generation(socket, :dialogue, Map.get(payload, "page_id"), payload)

  @impl true
  def handle_in("generate_dialogue_audio", payload, socket),
    do: enqueue_generation(socket, :dialogue_tts, Map.get(payload, "dialogue_line_id"), payload)

  @impl true
  def handle_in("generate_narration_audio", payload, socket),
    do: enqueue_generation(socket, :narration_tts, Map.get(payload, "page_id"), payload)

  @impl true
  def handle_in("generate_music", payload, socket),
    do: enqueue_generation(socket, :music, Map.get(payload, "track_id"), payload)

  @impl true
  def handle_in("generate_all_scenes", payload, socket),
    do: enqueue_generation(socket, :all_scenes, nil, payload)

  @impl true
  def handle_in("generate_all_dialogue", payload, socket),
    do: enqueue_generation(socket, :all_dialogue, nil, payload)

  @impl true
  def handle_in("generate_all_audio", payload, socket),
    do: enqueue_generation(socket, :all_audio, nil, payload)

  @impl true
  def handle_in("generate_all", payload, socket),
    do: enqueue_generation(socket, :all, nil, payload)

  @impl true
  def handle_in("retry_generation", payload, socket) do
    with {:ok, job_id} <- required_field(payload, "job_id"),
         {:ok, job} <- Generation.retry(socket.assigns.story_id, job_id, payload) do
      broadcast!(socket, "generation_started", %{
        story_id: socket.assigns.story_id,
        job_type: to_string(job.job_type),
        target_id: job.target_id,
        job_id: job.id,
        retried_from_job_id: job_id
      })

      {:reply, {:ok, %{job_id: job.id, status: "pending"}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in("deploy_story", payload, socket) do
    with {:ok, subdomain} <- required_field(payload, "subdomain"),
         {:ok, job} <- Generation.enqueue_deploy(socket.assigns.story_id, subdomain, payload) do
      broadcast!(socket, "deploy_started", %{story_id: socket.assigns.story_id, job_id: job.id})
      {:reply, {:ok, %{job_id: job.id, status: "pending"}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  @impl true
  def handle_in(event, _payload, socket) do
    {:reply, {:error, %{error: "unsupported_event", event: event}}, socket}
  end

  defp enqueue_generation(socket, generation_type, target_id, payload) do
    with {:ok, job} <-
           Generation.enqueue(socket.assigns.story_id, generation_type, target_id, payload) do
      broadcast!(socket, "generation_started", %{
        story_id: socket.assigns.story_id,
        job_type: to_string(generation_type),
        target_id: target_id,
        job_id: job.id
      })

      {:reply, {:ok, %{job_id: job.id, status: "pending"}}, socket}
    else
      {:error, reason} -> {:reply, {:error, normalize_error(reason)}, socket}
    end
  end

  defp required_id(payload), do: required_field(payload, "id")

  defp required_field(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end

  defp normalize_error({:error, reason}), do: normalize_error(reason)

  defp normalize_error(:not_found), do: %{error: "not_found"}
  defp normalize_error(:missing_id), do: %{error: "missing_id"}
  defp normalize_error({:missing_field, key}), do: %{error: "missing_field", field: key}
  defp normalize_error(:invalid_page_order), do: %{error: "invalid_page_order"}
  defp normalize_error(:invalid_subdomain), do: %{error: "invalid_subdomain"}
  defp normalize_error(:story_missing_content), do: %{error: "story_missing_content"}
  defp normalize_error(:nothing_to_generate), do: %{error: "nothing_to_generate"}
  defp normalize_error(:retry_not_supported), do: %{error: "retry_not_supported"}

  defp normalize_error(%Ecto.Changeset{} = changeset) do
    %{error: "validation_failed", details: traverse_errors(changeset)}
  end

  defp normalize_error(other), do: %{error: to_string(other)}

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end

  defp story_payload(story) do
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

  defp character_payload(character) do
    %{
      id: character.id,
      story_id: character.story_id,
      name: character.name,
      visual_description: character.visual_description,
      voice_provider: character.voice_provider,
      voice_id: character.voice_id,
      voice_model_id: character.voice_model_id,
      headshot_url: character.headshot_url,
      sort_order: character.sort_order
    }
  end

  defp page_payload(page) do
    %{
      id: page.id,
      story_id: page.story_id,
      page_index: page.page_index,
      scene_description: page.scene_description,
      narration_text: page.narration_text,
      scene_image_url: page.scene_image_url,
      narration_audio_url: page.narration_audio_url,
      narration_timings_url: page.narration_timings_url,
      sort_order: page.sort_order
    }
  end

  defp dialogue_payload(line) do
    %{
      id: line.id,
      page_id: line.page_id,
      character_id: line.character_id,
      text: line.text,
      audio_url: line.audio_url,
      timings_url: line.timings_url,
      sort_order: line.sort_order
    }
  end

  defp music_track_payload(track) do
    %{
      id: track.id,
      story_id: track.story_id,
      title: track.title,
      mood: track.mood,
      audio_url: track.audio_url
    }
  end

  defp music_span_payload(span) do
    %{
      id: span.id,
      track_id: span.track_id,
      start_page_index: span.start_page_index,
      end_page_index: span.end_page_index,
      loop: span.loop
    }
  end
end
