defmodule Storytime.Workers.TtsGenWorker do
  @moduledoc """
  Generates narration/dialogue audio and WordTimings V2 payloads.
  """

  use Oban.Worker, queue: :generation, max_attempts: 6

  alias Storytime.Assets
  alias Storytime.Stories
  alias Storytime.WordTimings

  @elevenlabs_base "https://api.elevenlabs.io/v1/text-to-speech"
  @openai_speech_url "https://api.openai.com/v1/audio/speech"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, type} <- required_arg(args, "type"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, item} <- fetch_target(story, type, target_id),
         {:ok, text, voice_id, model_id} <- tts_input(type, item),
         :ok <- mark_running(generation_job_id),
         {:ok, audio_bytes, alignment, provider} <- synthesize(text, voice_id, model_id),
         {:ok, audio_filename, timings_filename} <- filenames(type, target_id),
         {:ok, audio_url} <- Assets.write_binary(story_id, audio_filename, audio_bytes),
         timings <- WordTimings.from_alignment(text, alignment),
         {:ok, timings_url} <- Assets.write_json(story_id, timings_filename, timings),
         {:ok, _} <- persist_urls(story_id, type, target_id, audio_url, timings_url),
         :ok <- mark_completed(generation_job_id) do
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
        handle_failure(args, reason)
    end
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  defp fetch_story(story_id) do
    case Stories.load_story_graph(story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp fetch_target(story, "dialogue", target_id) do
    story.pages
    |> Enum.flat_map(& &1.dialogue_lines)
    |> Enum.find(&(&1.id == target_id))
    |> case do
      nil -> {:error, :dialogue_not_found}
      line -> {:ok, line}
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
    character = find_character(line)

    text = line.text || ""

    if text == "" do
      {:error, :empty_text}
    else
      {:ok, text, character && character.voice_id, character && character.voice_model_id}
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

  defp find_character(line) do
    case Map.get(line, :character) do
      nil -> nil
      character -> character
    end
  end

  defp filenames("dialogue", target_id), do: {:ok, "dialogue_#{target_id}.mp3", "dialogue_#{target_id}_timings.json"}
  defp filenames("narration", target_id), do: {:ok, "narration_#{target_id}.mp3", "narration_#{target_id}_timings.json"}
  defp filenames(_type, _target_id), do: {:error, :unsupported_tts_type}

  defp synthesize(text, voice_id, model_id) do
    with {:error, _} <- maybe_elevenlabs(text, voice_id, model_id),
         {:ok, audio_bytes} <- openai_speech(text) do
      {:ok, audio_bytes, nil, "openai_tts"}
    else
      {:ok, audio_bytes, alignment} -> {:ok, audio_bytes, alignment, "elevenlabs"}
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

  defp openai_speech(text) do
    api_key = System.get_env("OPENAI_API_KEY")

    if blank?(api_key) do
      {:error, :missing_openai_api_key}
    else
      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      body = %{
        model: "gpt-4o-mini-tts",
        voice: "alloy",
        input: text,
        format: "mp3"
      }

      case Req.post(@openai_speech_url, headers: headers, json: body) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, {:openai_speech_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_urls(story_id, "dialogue", target_id, audio_url, timings_url) do
    Stories.set_dialogue_audio(story_id, target_id, audio_url, timings_url)
  end

  defp persist_urls(story_id, "narration", target_id, audio_url, timings_url) do
    Stories.set_page_narration(story_id, target_id, audio_url, timings_url)
  end

  defp persist_urls(_story_id, _type, _target_id, _audio_url, _timings_url), do: {:error, :unsupported_tts_type}

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

    _ = status_update(generation_job_id, :failed, inspect(reason))

    if story_id do
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
end
