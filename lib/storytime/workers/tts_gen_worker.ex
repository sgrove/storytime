defmodule Storytime.Workers.TtsGenWorker do
  @moduledoc """
  Generates narration/dialogue audio and WordTimings V2 payloads.
  """

  use Oban.Worker, queue: :generation, max_attempts: 6

  alias Storytime.Assets
  alias Storytime.Stories
  alias Storytime.WordTimings

  @elevenlabs_base "https://api.elevenlabs.io/v1/text-to-speech"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    do_perform(args)
  rescue
    exception ->
      handle_failure(args, {:unhandled_exception, Exception.message(exception)})
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  defp do_perform(args) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, type} <- required_arg(args, "type"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, item} <- fetch_target(story, type, target_id) do
      case existing_audio_urls(type, item) do
        {:ok, audio_url, timings_url} ->
          complete_from_cached(
            story_id,
            type,
            target_id,
            generation_job_id,
            audio_url,
            timings_url
          )

        :none ->
          with {:ok, text, voice_id, model_id} <- tts_input(type, item),
               :ok <- mark_running(generation_job_id),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 10),
               {:ok, audio_bytes, alignment, provider} <- synthesize(text, voice_id, model_id),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 75),
               {:ok, audio_filename, timings_filename} <- filenames(type, target_id),
               {:ok, audio_url} <- Assets.write_binary(story_id, audio_filename, audio_bytes),
               timings <- WordTimings.from_alignment(text, alignment),
               {:ok, timings_url} <- Assets.write_json(story_id, timings_filename, timings),
               {:ok, _} <- persist_urls(story_id, type, target_id, audio_url, timings_url),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 95),
               :ok <- mark_completed(generation_job_id) do
            _ = Stories.maybe_mark_story_ready(story_id)
            broadcast_progress(story_id, type, target_id, generation_job_id, 100)

            StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
              story_id: story_id,
              job_type: map_job_type(type),
              target_id: target_id,
              job_id: generation_job_id,
              url: audio_url,
              timings_url: timings_url
            })

            {:ok, %{url: audio_url, timings_url: timings_url, provider: provider}}
          else
            {:error, reason} ->
              resolve_synthesis_error(
                args,
                reason,
                story_id,
                type,
                target_id,
                generation_job_id
              )
          end
      end
    else
      {:error, reason} ->
        resolve_setup_error(args, reason)
    end
  end

  defp fetch_story(story_id) do
    case Stories.load_story_graph(story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp fetch_target(story, "dialogue", target_id) do
    character_by_id = Map.new(story.characters || [], &{&1.id, &1})

    story.pages
    |> Enum.flat_map(& &1.dialogue_lines)
    |> Enum.find(&(&1.id == target_id))
    |> case do
      nil -> {:error, :dialogue_not_found}
      line -> {:ok, %{line | character: Map.get(character_by_id, line.character_id)}}
    end
  end

  defp fetch_target(story, "narration", target_id) do
    case Enum.find(story.pages, &(&1.id == target_id)) do
      nil -> {:error, :page_not_found}
      page -> {:ok, page}
    end
  end

  defp fetch_target(_story, _type, _target_id), do: {:error, :unsupported_tts_type}

  defp tts_input("dialogue", line) do
    text = line.text || ""
    {voice_id, model_id} = dialogue_voice_ids(line)

    if text == "" do
      {:error, :empty_text}
    else
      if blank?(voice_id) do
        {:error, :missing_character_voice_id}
      else
        {:ok, text, voice_id, model_id}
      end
    end
  end

  defp tts_input("narration", page) do
    text = page.narration_text || ""

    if text == "" do
      {:error, :empty_text}
    else
      {:ok, text, nil, nil}
    end
  end

  @doc false
  def dialogue_voice_ids(line) do
    character = find_character(line)

    if character do
      {character.voice_id, character.voice_model_id}
    else
      {nil, nil}
    end
  end

  defp find_character(line) do
    case Map.get(line, :character) do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> nil
      character -> character
    end
  end

  defp filenames("dialogue", target_id),
    do: {:ok, "dialogue_#{target_id}.mp3", "dialogue_#{target_id}_timings.json"}

  defp filenames("narration", target_id),
    do: {:ok, "narration_#{target_id}.mp3", "narration_#{target_id}_timings.json"}

  defp filenames(_type, _target_id), do: {:error, :unsupported_tts_type}

  defp synthesize(text, voice_id, model_id) do
    with {:ok, audio_bytes, alignment} <- maybe_elevenlabs(text, voice_id, model_id) do
      {:ok, audio_bytes, alignment, "elevenlabs"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_elevenlabs(text, voice_id, model_id) do
    api_key = System.get_env("ELEVENLABS_API_KEY")

    cond do
      blank?(api_key) ->
        {:error, :missing_elevenlabs_api_key}

      true ->
        chosen_voice = voice_id || System.get_env("ELEVENLABS_DEFAULT_VOICE_ID")

        if blank?(chosen_voice) do
          {:error, :missing_voice_id}
        else
          chosen_model = model_id || "eleven_multilingual_v2"

          url = "#{@elevenlabs_base}/#{chosen_voice}/with-timestamps"

          headers = [
            {"xi-api-key", api_key},
            {"content-type", "application/json"}
          ]

          body = %{
            text: text,
            model_id: chosen_model,
            output_format: "mp3_44100_128"
          }

          case Req.post(url, headers: headers, json: body) do
            {:ok,
             %{
               status: 200,
               body: %{"audio_base64" => audio_b64} = response
             }} ->
              case Base.decode64(audio_b64) do
                {:ok, audio_bytes} ->
                  alignment = response["normalized_alignment"] || response["alignment"]
                  {:ok, audio_bytes, alignment}

                :error ->
                  {:error, :invalid_audio_payload}
              end

            {:ok, %{status: status, body: body}} ->
              {:error, {:elevenlabs_error, status, body}}

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp persist_urls(story_id, "dialogue", target_id, audio_url, timings_url) do
    Stories.set_dialogue_audio(story_id, target_id, audio_url, timings_url)
  end

  defp persist_urls(story_id, "narration", target_id, audio_url, timings_url) do
    Stories.set_page_narration(story_id, target_id, audio_url, timings_url)
  end

  defp persist_urls(_story_id, _type, _target_id, _audio_url, _timings_url),
    do: {:error, :unsupported_tts_type}

  @doc false
  def existing_audio_urls("dialogue", line) do
    if blank?(line.audio_url) or blank?(line.timings_url) do
      :none
    else
      {:ok, line.audio_url, line.timings_url}
    end
  end

  def existing_audio_urls("narration", page) do
    if blank?(page.narration_audio_url) or blank?(page.narration_timings_url) do
      :none
    else
      {:ok, page.narration_audio_url, page.narration_timings_url}
    end
  end

  def existing_audio_urls(_type, _item), do: :none

  defp complete_from_cached(story_id, type, target_id, generation_job_id, audio_url, timings_url) do
    with :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, type, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: map_job_type(type),
        target_id: target_id,
        job_id: generation_job_id,
        url: audio_url,
        timings_url: timings_url,
        reused: true
      })

      {:ok, %{url: audio_url, timings_url: timings_url, provider: "cached", reused: true}}
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
    type = Map.get(args, "type")
    target_id = Map.get(args, "target_id")

    if is_binary(generation_job_id) do
      _ = status_update(generation_job_id, :failed, inspect(reason))
    end

    if story_id do
      _ = Stories.maybe_mark_story_ready(story_id)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_failed", %{
        story_id: story_id,
        job_type: map_job_type(type),
        target_id: target_id,
        job_id: generation_job_id,
        error: inspect(reason)
      })
    end

    {:error, reason}
  end

  defp resolve_synthesis_error(args, :empty_text, story_id, type, target_id, generation_job_id) do
    complete_without_audio(story_id, type, target_id, generation_job_id, "empty_text", args)
  end

  defp resolve_synthesis_error(args, reason, _story_id, _type, _target_id, _generation_job_id) do
    if non_retryable_reason?(reason) do
      _ = handle_failure(args, reason)
      {:discard, reason}
    else
      handle_failure(args, reason)
    end
  end

  defp resolve_setup_error(args, reason) do
    if non_retryable_reason?(reason) do
      _ = handle_failure(args, reason)
      {:discard, reason}
    else
      handle_failure(args, reason)
    end
  end

  defp complete_without_audio(story_id, type, target_id, generation_job_id, skip_reason, args) do
    with :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, type, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: map_job_type(type),
        target_id: target_id,
        job_id: generation_job_id,
        skipped: true,
        skipped_reason: skip_reason
      })

      {:ok, %{skipped: true, reason: skip_reason}}
    else
      {:error, reason} -> handle_failure(args, reason)
    end
  end

  @doc false
  def non_retryable_reason?(:empty_text), do: true
  def non_retryable_reason?(:missing_character_voice_id), do: true
  def non_retryable_reason?(:missing_voice_id), do: true
  def non_retryable_reason?(:missing_elevenlabs_api_key), do: true
  def non_retryable_reason?(:unsupported_tts_type), do: true
  def non_retryable_reason?(:dialogue_not_found), do: true
  def non_retryable_reason?(:page_not_found), do: true
  def non_retryable_reason?(:story_not_found), do: true
  def non_retryable_reason?({:missing_arg, _key}), do: true
  def non_retryable_reason?(_reason), do: false

  defp map_job_type("dialogue"), do: "dialogue_tts"
  defp map_job_type("narration"), do: "narration_tts"
  defp map_job_type(_), do: "dialogue_tts"

  defp required_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp broadcast_progress(story_id, type, target_id, job_id, progress) do
    StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_progress", %{
      story_id: story_id,
      job_type: map_job_type(type),
      target_id: target_id,
      job_id: job_id,
      progress: progress
    })
  end

  defp emit_progress(story_id, type, target_id, job_id, progress) do
    broadcast_progress(story_id, type, target_id, job_id, progress)
    :ok
  end
end
