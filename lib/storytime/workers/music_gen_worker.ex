defmodule Storytime.Workers.MusicGenWorker do
  @moduledoc """
  Generates background music via Sonauto with fallback synthesis.
  """

  use Oban.Worker, queue: :generation, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Stories

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, track} <- find_track(story, target_id),
         :ok <- mark_running(generation_job_id),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 10),
         {:ok, audio_bytes, provider} <- generate_music(track),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 75),
         {:ok, asset_url} <- Assets.write_binary(story_id, "music_#{target_id}.mp3", audio_bytes),
         {:ok, _} <- Stories.set_music_audio(story_id, target_id, asset_url),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 95),
         :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: "music",
        target_id: target_id,
        job_id: generation_job_id,
        url: asset_url
      })

      {:ok, %{url: asset_url, provider: provider}}
    else
      {:error, reason} -> handle_failure(args, reason)
    end
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  defp fetch_story(story_id) do
    case Stories.load_story_graph(story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp find_track(story, track_id) do
    case Enum.find(story.music_tracks, &(&1.id == track_id)) do
      nil -> {:error, :track_not_found}
      track -> {:ok, track}
    end
  end

  defp generate_music(track) do
    prompt =
      "Gentle instrumental children's story background music, mood: #{track.mood || "calm"}."

    case maybe_sonauto(prompt) do
      {:ok, bytes} -> {:ok, bytes, "sonauto"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_sonauto(prompt) do
    api_key = System.get_env("SONAUTO_API_KEY")

    if blank?(api_key) do
      {:error, :missing_sonauto_api_key}
    else
      base = System.get_env("SONAUTO_API_BASE") || "https://api.sonauto.ai/v1"

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      create_body = %{prompt: prompt, duration_seconds: 20}

      with {:ok, %{status: status, body: create_body}} when status in [200, 201] <-
             Req.post("#{base}/create", headers: headers, json: create_body),
           task_id when is_binary(task_id) <- extract_task_id(create_body),
           {:ok, audio_url} <- poll_sonauto_audio_url(base, headers, task_id, 10),
           {:ok, %{status: 200, body: audio_bytes}} when is_binary(audio_bytes) <-
             Req.get(audio_url) do
        {:ok, audio_bytes}
      else
        {:ok, %{status: status, body: body}} -> {:error, {:sonauto_error, status, body}}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :sonauto_unexpected_response}
      end
    end
  end

  defp extract_task_id(body) when is_map(body) do
    body["id"] || body["task_id"] || body["job_id"]
  end

  defp extract_task_id(_), do: nil

  defp poll_sonauto_audio_url(_base, _headers, _task_id, 0), do: {:error, :sonauto_timeout}

  defp poll_sonauto_audio_url(base, headers, task_id, attempts_left) do
    status_url = "#{base}/create/#{task_id}"

    case Req.get(status_url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        cond do
          is_binary(body["audio_url"]) ->
            {:ok, body["audio_url"]}

          is_binary(body["url"]) ->
            {:ok, body["url"]}

          body["status"] in ["failed", "error"] ->
            {:error, {:sonauto_failed, body}}

          true ->
            Process.sleep(1500)
            poll_sonauto_audio_url(base, headers, task_id, attempts_left - 1)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:sonauto_poll_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_running(job_id), do: status_update(job_id, :running)
  defp mark_completed(job_id), do: status_update(job_id, :completed)

  defp status_update(job_id, status, error \\ nil) do
    case Stories.set_generation_job_status(job_id, status, error) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_failure(args, reason) do
    generation_job_id = Map.get(args, "generation_job_id")
    story_id = Map.get(args, "story_id")
    target_id = Map.get(args, "target_id")

    _ = status_update(generation_job_id, :failed, inspect(reason))

    if story_id do
      _ = Stories.maybe_mark_story_ready(story_id)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_failed", %{
        story_id: story_id,
        job_type: "music",
        target_id: target_id,
        job_id: generation_job_id,
        error: inspect(reason)
      })
    end

    {:error, reason}
  end

  defp required_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp broadcast_progress(story_id, target_id, job_id, progress) do
    StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_progress", %{
      story_id: story_id,
      job_type: "music",
      target_id: target_id,
      job_id: job_id,
      progress: progress
    })
  end

  defp emit_progress(story_id, target_id, job_id, progress) do
    broadcast_progress(story_id, target_id, job_id, progress)
    :ok
  end
end
