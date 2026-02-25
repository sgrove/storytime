defmodule Storytime.Workers.DialogueGenWorker do
  @moduledoc """
  Generates page dialogue text via LLM and immediately queues dialogue TTS jobs.
  """

  use Oban.Worker, queue: :generation, max_attempts: 4

  alias Storytime.Generation
  alias Storytime.Stories
  alias Storytime.Stories.Page

  @openai_chat_url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-5.2"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, payload} <- payload_arg(args),
         {:ok, story} <- fetch_story(story_id),
         {:ok, page} <- fetch_page(story, target_id),
         {:ok, voiced_characters} <- voiced_characters(story),
         line_count <- requested_line_count(payload, voiced_characters),
         :ok <- mark_running(generation_job_id),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 10),
         {:ok, generated_lines} <-
           generate_lines(story, page, voiced_characters, line_count, payload),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 45),
         {:ok, created_lines} <-
           Stories.replace_page_dialogue_lines(story_id, target_id, generated_lines),
         :ok <- broadcast_created_lines(story_id, created_lines),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 65),
         {:ok, queued_jobs} <- enqueue_tts(story_id, created_lines),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 95),
         :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: "dialogue",
        target_id: target_id,
        job_id: generation_job_id,
        queued_tts_jobs: Enum.map(queued_jobs, & &1.id),
        generated_line_ids: Enum.map(created_lines, & &1.id)
      })

      {:ok, %{queued_tts_jobs: length(queued_jobs), generated_lines: length(created_lines)}}
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

  defp fetch_page(story, target_id) do
    case Enum.find(story.pages, &(&1.id == target_id)) do
      %Page{} = page -> {:ok, page}
      nil -> {:error, :page_not_found}
    end
  end

  defp voiced_characters(story) do
    available =
      story.characters
      |> Enum.filter(&(not blank?(&1.voice_id)))
      |> Enum.sort_by(&((&1.sort_order || 0) * 1000))

    case available do
      [] -> {:error, :missing_character_voices}
      chars -> {:ok, chars}
    end
  end

  defp requested_line_count(payload, voiced_characters) do
    payload
    |> Map.get("line_count")
    |> case do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> nil
        end

      _ ->
        nil
    end
    |> case do
      nil ->
        max(min(length(voiced_characters), 6), 2)

      value ->
        value
    end
    |> min(8)
    |> max(1)
  end

  defp generate_lines(story, page, characters, line_count, payload) do
    with {:ok, content} <- call_openai_dialogue(story, page, characters, line_count, payload),
         {:ok, decoded} <- decode_dialogue_json(content),
         {:ok, lines} <- normalize_llm_lines(decoded, characters, line_count) do
      {:ok, lines}
    end
  end

  defp call_openai_dialogue(story, page, characters, line_count, payload) do
    api_key = System.get_env("OPENAI_API_KEY")

    if blank?(api_key) do
      {:error, :missing_openai_api_key}
    else
      model = payload["model"] || System.get_env("DIALOGUE_LLM_MODEL") || @default_model
      messages = build_messages(story, page, characters, line_count)

      body = %{
        model: model,
        temperature: 0.9,
        response_format: %{type: "json_object"},
        messages: messages
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(@openai_chat_url, headers: headers, json: body) do
        {:ok, %{status: 200, body: response_body}} ->
          extract_openai_content(response_body)

        {:ok, %{status: status, body: response_body}} ->
          {:error, {:openai_error, status, response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc false
  @spec extract_openai_content(map()) :: {:ok, String.t()} | {:error, :invalid_llm_response}
  def extract_openai_content(%{"choices" => [%{"message" => %{"content" => content}} | _]})
      when is_binary(content) do
    {:ok, content}
  end

  def extract_openai_content(%{
        "choices" => [
          %{"message" => %{"content" => [%{"type" => "text", "text" => text} | _]}} | _
        ]
      })
      when is_binary(text) do
    {:ok, text}
  end

  def extract_openai_content(_), do: {:error, :invalid_llm_response}

  defp decode_dialogue_json(content) when is_binary(content) do
    content
    |> trim_json_fence()
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_dialogue_json}
    end
  end

  @doc false
  @spec normalize_llm_lines(term(), [map()], pos_integer()) ::
          {:ok, [%{character_id: String.t(), text: String.t()}]}
          | {:error, :invalid_dialogue_lines}
  def normalize_llm_lines(decoded, characters, line_count)
      when is_list(characters) and is_integer(line_count) and line_count > 0 do
    fallback_character = List.first(characters)

    char_id_by_name =
      Map.new(characters, fn character ->
        {normalize_name(character.name), character.id}
      end)

    raw_lines =
      case decoded do
        %{"lines" => lines} when is_list(lines) -> lines
        lines when is_list(lines) -> lines
        _ -> []
      end

    parsed =
      raw_lines
      |> Enum.with_index()
      |> Enum.map(fn {line, idx} ->
        pick_line(line, idx, line_count, characters, char_id_by_name, fallback_character)
      end)
      |> Enum.filter(&is_map/1)
      |> Enum.take(line_count)

    if parsed == [] do
      {:error, :invalid_dialogue_lines}
    else
      {:ok, parsed}
    end
  end

  defp pick_line(line, idx, _line_count, characters, char_id_by_name, fallback_character)
       when is_map(line) do
    text =
      line
      |> Map.get("text", Map.get(line, "line", ""))
      |> to_string()
      |> String.trim()

    chosen_character_id =
      line
      |> resolve_character_id(characters, char_id_by_name)
      |> case do
        nil ->
          case Enum.at(characters, rem(idx, max(length(characters), 1))) do
            nil -> fallback_character && fallback_character.id
            character -> character.id
          end

        id ->
          id
      end

    if text == "" or blank?(chosen_character_id) do
      nil
    else
      %{character_id: chosen_character_id, text: text}
    end
  end

  defp pick_line(_line, _idx, _line_count, _characters, _char_id_by_name, _fallback_character),
    do: nil

  defp resolve_character_id(line, characters, char_id_by_name) do
    direct = Map.get(line, "character_id") || Map.get(line, "characterId")

    cond do
      is_binary(direct) and Enum.any?(characters, &(&1.id == direct)) ->
        direct

      is_binary(Map.get(line, "character_name")) ->
        Map.get(char_id_by_name, normalize_name(Map.get(line, "character_name")))

      is_binary(Map.get(line, "characterName")) ->
        Map.get(char_id_by_name, normalize_name(Map.get(line, "characterName")))

      true ->
        nil
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_name(_), do: ""

  defp build_messages(story, page, characters, line_count) do
    voice_constraints =
      characters
      |> Enum.map(fn character ->
        %{
          id: character.id,
          name: character.name,
          voice_id: character.voice_id,
          voice_model_id: character.voice_model_id
        }
      end)

    story_payload = %{
      title: story.title,
      art_style: story.art_style,
      page_index: page.page_index,
      scene_description: page.scene_description,
      narration_text: page.narration_text,
      requested_line_count: line_count,
      characters: voice_constraints
    }

    [
      %{
        role: "system",
        content:
          "You write concise children story dialogue. Return only valid JSON and nothing else."
      },
      %{
        role: "user",
        content: """
        Generate page dialogue lines for this story page.

        Requirements:
        - Output JSON object: {"lines":[{"character_id":"...","text":"..."}]}
        - Produce #{line_count} lines total.
        - Each line text must be <= 180 characters, kid-friendly, and fit the narration/scene.
        - Use only character_id values provided in input.
        - Include a mix of the available characters when possible.

        Input:
        #{Jason.encode!(story_payload)}
        """
      }
    ]
  end

  defp enqueue_tts(story_id, created_lines) do
    created_lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Generation.enqueue(story_id, :dialogue_tts, line.id, %{
             "source" => "dialogue_generation"
           }) do
        {:ok, job} ->
          StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_started", %{
            story_id: story_id,
            job_type: "dialogue_tts",
            target_id: line.id,
            job_id: job.id
          })

          {:cont, {:ok, [job | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp broadcast_created_lines(story_id, lines) do
    Enum.each(lines, fn line ->
      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "dialogue_line_added", %{
        line: %{
          id: line.id,
          page_id: line.page_id,
          character_id: line.character_id,
          text: line.text,
          audio_url: line.audio_url,
          timings_url: line.timings_url,
          sort_order: line.sort_order
        }
      })
    end)

    :ok
  end

  defp trim_json_fence(content) do
    content
    |> String.trim()
    |> String.replace_prefix("```json", "")
    |> String.replace_prefix("```", "")
    |> String.replace_suffix("```", "")
    |> String.trim()
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
        job_type: "dialogue",
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

  defp payload_arg(args) do
    case Map.get(args, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _ -> {:error, {:missing_arg, "payload"}}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp broadcast_progress(story_id, target_id, job_id, progress) do
    StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_progress", %{
      story_id: story_id,
      job_type: "dialogue",
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
