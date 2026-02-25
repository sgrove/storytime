defmodule Storytime.Workers.MusicGenWorker do
  @moduledoc """
  Generates background music via Sonauto.
  """

  use Oban.Worker, queue: :generation, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Stories

  @sonauto_api_base_default "https://api.sonauto.ai/v1"
  @sonauto_poll_attempts_default 40
  @sonauto_poll_sleep_ms_default 3_000
  @sonauto_request_timeout_ms_default 180_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, track} <- find_track(story, target_id) do
      case reusable_track_audio(track, args) do
        {:ok, asset_url} ->
          complete_from_cached(story_id, target_id, generation_job_id, asset_url)

        :none ->
          with :ok <- mark_running(generation_job_id),
               :ok <- emit_progress(story_id, target_id, generation_job_id, 10),
               {:ok, audio_bytes, provider} <- generate_music(track),
               :ok <- emit_progress(story_id, target_id, generation_job_id, 75),
               {:ok, asset_url} <-
                 Assets.write_binary(story_id, "music_#{target_id}.mp3", audio_bytes),
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
            {:error, reason} -> resolve_failure(args, reason)
          end
      end
    else
      {:error, reason} -> resolve_failure(args, reason)
    end
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  @doc false
  def reusable_track_audio(track, args) do
    if force_payload?(args) do
      :none
    else
      existing_track_audio(track)
    end
  end

  @doc false
  def force_payload?(args) when is_map(args) do
    payload = Map.get(args, "payload") || Map.get(args, :payload) || %{}

    Map.get(payload, "force") in [true, "true", 1, "1"] or
      Map.get(payload, :force) in [true, "true", 1, "1"]
  end

  def force_payload?(_args), do: false

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
      base = sonauto_api_base()

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ]

      with {:ok, create_body} <- create_sonauto_generation(base, headers, prompt),
           task_id when is_binary(task_id) <- extract_task_id(create_body),
           {:ok, audio_url} <-
             poll_sonauto_audio_url(
               base,
               headers,
               task_id,
               sonauto_poll_attempts(),
               sonauto_poll_sleep_ms()
             ),
           {:ok, %{status: 200, body: audio_bytes}} when is_binary(audio_bytes) <-
             Req.get(audio_url,
               receive_timeout: sonauto_request_timeout_ms(),
               pool_timeout: sonauto_request_timeout_ms(),
               connect_options: [timeout: 30_000],
               retry: false
             ) do
        {:ok, audio_bytes}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :sonauto_unexpected_response}
      end
    end
  end

  defp create_sonauto_generation(base, headers, prompt) do
    with {:error, reason} <-
           request_sonauto_generation(base, headers, build_create_payload(prompt)),
         {:ok, body} <- retry_without_tags_if_invalid(base, headers, prompt, reason) do
      {:ok, body}
    else
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_without_tags_if_invalid(base, headers, prompt, {:sonauto_error, 422, body}) do
    if invalid_tags_error?(body) do
      request_sonauto_generation(base, headers, build_create_payload(prompt, false))
    else
      {:error, {:sonauto_error, 422, body}}
    end
  end

  defp retry_without_tags_if_invalid(_base, _headers, _prompt, reason), do: {:error, reason}

  defp request_sonauto_generation(base, headers, create_payload) do
    case Req.post("#{base}/generations",
           headers: headers,
           json: create_payload,
           receive_timeout: sonauto_request_timeout_ms(),
           pool_timeout: sonauto_request_timeout_ms(),
           connect_options: [timeout: 30_000],
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201, 202] ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:sonauto_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_create_payload(prompt, include_tags \\ true) do
    payload = %{
      prompt: prompt,
      instrumental: true,
      output_format: "mp3"
    }

    if include_tags do
      Map.put(payload, :tags, sonauto_tags(prompt))
    else
      payload
    end
  end

  @doc false
  def extract_task_id(body) when is_map(body) do
    body["id"] || body["task_id"] || body["job_id"]
  end

  def extract_task_id(_), do: nil

  @doc false
  def extract_audio_url(body) when is_map(body) do
    body["song_path"] || body["audio_url"] || body["url"] || body["download_url"]
  end

  def extract_audio_url(_), do: nil

  @doc false
  def invalid_tags_error?(%{"detail" => detail}) when is_list(detail) do
    Enum.any?(detail, fn entry ->
      message =
        entry
        |> case do
          %{"msg" => msg} -> msg
          %{msg: msg} -> msg
          _ -> nil
        end

      is_binary(message) and String.contains?(String.downcase(message), "invalid tags")
    end)
  end

  def invalid_tags_error?(_), do: false

  defp poll_sonauto_audio_url(_base, _headers, _task_id, 0, _sleep_ms),
    do: {:error, :sonauto_timeout}

  defp poll_sonauto_audio_url(base, headers, task_id, attempts_left, sleep_ms) do
    status_url = "#{base}/generations/#{task_id}"

    case Req.get(status_url,
           headers: headers,
           receive_timeout: sonauto_request_timeout_ms(),
           pool_timeout: sonauto_request_timeout_ms(),
           connect_options: [timeout: 30_000],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        audio_url = extract_audio_url(body)
        status = normalize_task_status(body["status"])

        cond do
          is_binary(audio_url) and audio_url != "" ->
            {:ok, normalize_audio_url(base, audio_url)}

          status == :failed ->
            {:error, {:sonauto_failed, body}}

          status == :pending ->
            Process.sleep(sleep_ms)
            poll_sonauto_audio_url(base, headers, task_id, attempts_left - 1, sleep_ms)

          true ->
            Process.sleep(sleep_ms)
            poll_sonauto_audio_url(base, headers, task_id, attempts_left - 1, sleep_ms)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:sonauto_poll_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_audio_url(_base, url) when not is_binary(url), do: nil

  defp normalize_audio_url(base, url) do
    cond do
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        url

      String.starts_with?(url, "/") ->
        URI.merge(base, url) |> to_string()

      true ->
        url
    end
  end

  defp sonauto_api_base, do: System.get_env("SONAUTO_API_BASE") || @sonauto_api_base_default

  defp sonauto_tags(prompt) do
    base_tags = ["children", "instrumental", "background", "storybook"]

    mood_tags =
      prompt
      |> String.downcase()
      |> String.split(~r/[^a-z0-9]+/, trim: true)
      |> Enum.filter(
        &(&1 in ["calm", "gentle", "mysterious", "happy", "sad", "adventure", "peaceful"])
      )
      |> Enum.uniq()

    Enum.uniq(base_tags ++ mood_tags)
  end

  defp sonauto_poll_attempts do
    timeout_from_env(System.get_env("SONAUTO_POLL_ATTEMPTS"), @sonauto_poll_attempts_default, 5)
  end

  defp sonauto_poll_sleep_ms do
    timeout_from_env(System.get_env("SONAUTO_POLL_SLEEP_MS"), @sonauto_poll_sleep_ms_default, 500)
  end

  defp sonauto_request_timeout_ms do
    timeout_from_env(
      System.get_env("SONAUTO_REQUEST_TIMEOUT_MS"),
      @sonauto_request_timeout_ms_default,
      30_000
    )
  end

  defp timeout_from_env(raw_value, default_value, min_value) when is_binary(raw_value) do
    case Integer.parse(String.trim(raw_value)) do
      {value, ""} when value >= min_value -> value
      _ -> default_value
    end
  end

  defp timeout_from_env(_raw_value, default_value, _min_value), do: default_value

  @doc false
  def normalize_task_status(status) when is_binary(status) do
    normalized = String.downcase(String.trim(status))

    cond do
      normalized in ["complete", "completed", "succeeded", "done"] ->
        :complete

      normalized in ["failed", "error", "cancelled", "canceled"] ->
        :failed

      normalized in ["processing", "queued", "pending", "running", "in_progress", "started"] ->
        :pending

      true ->
        :pending
    end
  end

  def normalize_task_status(_), do: :pending

  @doc false
  def existing_track_audio(track) do
    if blank?(track.audio_url), do: :none, else: {:ok, track.audio_url}
  end

  defp complete_from_cached(story_id, target_id, generation_job_id, asset_url) do
    with :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: "music",
        target_id: target_id,
        job_id: generation_job_id,
        url: asset_url,
        reused: true
      })

      {:ok, %{url: asset_url, provider: "cached", reused: true}}
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

  defp resolve_failure(args, reason) do
    _ = handle_failure(args, reason)

    if non_retryable_reason?(reason) do
      {:discard, reason}
    else
      {:error, reason}
    end
  end

  @doc false
  def non_retryable_reason?(:missing_sonauto_api_key), do: true
  def non_retryable_reason?(:story_not_found), do: true
  def non_retryable_reason?(:track_not_found), do: true
  def non_retryable_reason?(:sonauto_unexpected_response), do: true
  def non_retryable_reason?({:missing_arg, _}), do: true
  def non_retryable_reason?({:sonauto_error, status, _}) when status in 400..499, do: true
  def non_retryable_reason?({:sonauto_poll_error, status, _}) when status in 400..499, do: true
  def non_retryable_reason?({:sonauto_failed, _}), do: true
  def non_retryable_reason?(_), do: false

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
