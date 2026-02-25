defmodule Storytime.Workers.DialogueGenWorker do
  @moduledoc """
  Generates page dialogue text via LLM and immediately queues dialogue TTS jobs.
  """

  use Oban.Worker, queue: :generation, max_attempts: 4

  alias Storytime.Assets
  alias Storytime.Generation
  alias Storytime.Notifier
  alias Storytime.Stories
  alias Storytime.Stories.Page
  alias Storytime.WordTimings

  @openai_chat_url "https://api.openai.com/v1/chat/completions"
  @elevenlabs_dialogue_url "https://api.elevenlabs.io/v1/text-to-dialogue/convert-with-timestamps"
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
         {:ok, timed_lines} <-
           persist_page_dialogue_timings(story_id, created_lines, story.characters),
         :ok <- broadcast_timing_updates(story_id, timed_lines),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 75),
         {:ok, queued_jobs} <- enqueue_tts(story_id, created_lines),
         :ok <- emit_progress(story_id, target_id, generation_job_id, 92),
         :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, target_id, generation_job_id, 100)

      Notifier.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: "dialogue",
        target_id: target_id,
        job_id: generation_job_id,
        queued_tts_jobs: Enum.map(queued_jobs, & &1.id),
        generated_line_ids: Enum.map(created_lines, & &1.id),
        timed_line_ids: Enum.map(timed_lines, & &1.id)
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
             "source" => "dialogue_generation",
             "preserve_timings" => true
           }) do
        {:ok, job} ->
          Notifier.broadcast("story:#{story_id}", "generation_started", %{
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
      Notifier.broadcast("story:#{story_id}", "dialogue_line_added", %{
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

  defp broadcast_timing_updates(story_id, lines) do
    Enum.each(lines, fn line ->
      Notifier.broadcast("story:#{story_id}", "dialogue_line_updated", %{
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

  defp persist_page_dialogue_timings(story_id, created_lines, characters) do
    with {:ok, dialogue_payload} <- request_dialogue_timestamps(created_lines, characters),
         {:ok, alignment} <- extract_character_alignment(dialogue_payload),
         {:ok, segments} <- extract_voice_segments(dialogue_payload),
         {:ok, updated_lines} <-
           persist_dialogue_line_timings(story_id, created_lines, alignment, segments) do
      {:ok, updated_lines}
    end
  end

  defp request_dialogue_timestamps(created_lines, characters) do
    api_key = System.get_env("ELEVENLABS_API_KEY")

    if blank?(api_key) do
      {:error, :missing_elevenlabs_api_key}
    else
      with {:ok, inputs} <- dialogue_inputs(created_lines, characters),
           {:ok, payload} <- post_dialogue_timestamp_request(api_key, inputs) do
        {:ok, payload}
      end
    end
  end

  defp dialogue_inputs(created_lines, characters) do
    by_id = Map.new(characters, &{&1.id, &1})

    inputs =
      created_lines
      |> Enum.map(fn line ->
        character = Map.get(by_id, line.character_id)
        voice_id = character && character.voice_id

        if blank?(voice_id) do
          {:error, :missing_character_voice_id}
        else
          {:ok, %{text: line.text || "", voice_id: voice_id}}
        end
      end)

    collect_ok_results(inputs)
  end

  defp post_dialogue_timestamp_request(api_key, inputs) do
    query = URI.encode_query(%{"output_format" => "mp3_44100_128"})
    url = "#{@elevenlabs_dialogue_url}?#{query}"

    headers = [
      {"xi-api-key", api_key},
      {"content-type", "application/json"}
    ]

    body = %{inputs: inputs}

    case Req.post(url, headers: headers, json: body) do
      {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:elevenlabs_dialogue_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_character_alignment(payload) when is_map(payload) do
    alignment =
      Map.get(payload, "normalized_alignment") ||
        Map.get(payload, "alignment")

    with %{} = alignment_map <- alignment,
         chars when is_list(chars) <- Map.get(alignment_map, "characters"),
         starts when is_list(starts) <- Map.get(alignment_map, "character_start_times_seconds"),
         ends when is_list(ends) <- Map.get(alignment_map, "character_end_times_seconds") do
      if length(chars) == length(starts) and length(chars) == length(ends) do
        {:ok,
         %{
           characters: Enum.map(chars, &to_string/1),
           starts: Enum.map(starts, &to_seconds/1),
           ends: Enum.map(ends, &to_seconds/1)
         }}
      else
        {:error, :invalid_dialogue_alignment}
      end
    else
      _ -> {:error, :invalid_dialogue_alignment}
    end
  end

  defp extract_voice_segments(payload) when is_map(payload) do
    case Map.get(payload, "voice_segments") do
      values when is_list(values) and values != [] -> {:ok, values}
      _ -> {:error, :invalid_dialogue_voice_segments}
    end
  end

  defp persist_dialogue_line_timings(story_id, created_lines, alignment, segments) do
    created_lines
    |> Enum.with_index()
    |> Enum.map(fn {line, idx} ->
      with {:ok, line_timing} <- timings_for_line(line, idx, alignment, segments),
           filename = "dialogue_#{line.id}_timings.json",
           {:ok, timings_url} <- Assets.write_json(story_id, filename, line_timing),
           {:ok, updated_line} <- Stories.set_dialogue_timings(story_id, line.id, timings_url) do
        {:ok, updated_line}
      end
    end)
    |> collect_ok_results()
  end

  defp timings_for_line(line, line_index, alignment, segments) do
    with {:ok, range} <- dialogue_char_range_for_line(line_index, segments),
         {:ok, sliced_alignment} <- slice_alignment_range(alignment, range) do
      {:ok, WordTimings.from_alignment(line.text || "", sliced_alignment)}
    end
  end

  defp dialogue_char_range_for_line(line_index, segments) do
    matching =
      segments
      |> Enum.filter(&(segment_dialogue_input_index(&1) == line_index))
      |> Enum.map(fn segment ->
        {segment_integer(segment, "character_start_index"),
         segment_integer(segment, "character_end_index")}
      end)

    case matching do
      [] ->
        case Enum.at(segments, line_index) do
          segment when is_map(segment) ->
            start_idx = segment_integer(segment, "character_start_index")
            end_idx = segment_integer(segment, "character_end_index")

            if is_integer(start_idx) and is_integer(end_idx) and start_idx >= 0 and
                 end_idx > start_idx do
              {:ok, %{start_index: start_idx, end_index: end_idx}}
            else
              {:error, {:missing_dialogue_segment_for_index, line_index}}
            end

          _ ->
            {:error, {:missing_dialogue_segment_for_index, line_index}}
        end

      values ->
        start_idx = values |> Enum.map(&elem(&1, 0)) |> Enum.min()
        end_idx = values |> Enum.map(&elem(&1, 1)) |> Enum.max()

        if is_integer(start_idx) and is_integer(end_idx) and start_idx >= 0 and
             end_idx > start_idx do
          {:ok, %{start_index: start_idx, end_index: end_idx}}
        else
          {:error, {:invalid_dialogue_segment_range, line_index}}
        end
    end
  end

  defp slice_alignment_range(alignment, %{start_index: start_idx, end_index: end_idx}) do
    chars = Map.get(alignment, :characters, [])
    starts = Map.get(alignment, :starts, [])
    ends = Map.get(alignment, :ends, [])
    char_count = length(chars)
    count = end_idx - start_idx

    cond do
      start_idx < 0 or count <= 0 or end_idx > char_count ->
        {:error, :dialogue_alignment_range_out_of_bounds}

      true ->
        slice_starts = Enum.slice(starts, start_idx, count)
        slice_ends = Enum.slice(ends, start_idx, count)
        base_start = List.first(slice_starts) || 0.0

        local_starts = Enum.map(slice_starts, &max(&1 - base_start, 0.0))
        local_ends = Enum.map(slice_ends, &max(&1 - base_start, 0.0))

        {:ok,
         %{
           "character_start_times_seconds" => local_starts,
           "character_end_times_seconds" => local_ends
         }}
    end
  end

  defp segment_dialogue_input_index(segment) do
    case segment_integer(segment, "dialogue_input_index") do
      value when is_integer(value) and value >= 0 -> value
      _ -> -1
    end
  end

  defp segment_integer(segment, key) when is_map(segment) do
    value = Map.get(segment, key)

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp segment_integer(_segment, _key), do: nil

  defp to_seconds(value) when is_integer(value), do: value * 1.0
  defp to_seconds(value) when is_float(value), do: value

  defp to_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp to_seconds(_value), do: 0.0

  defp collect_ok_results(results) when is_list(results) do
    results
    |> Enum.reduce_while([], fn
      {:ok, value}, acc -> {:cont, [value | acc]}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
      other, _acc -> {:halt, {:error, {:unexpected_result, other}}}
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      collected -> {:ok, Enum.reverse(collected)}
    end
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

      Notifier.broadcast("story:#{story_id}", "generation_failed", %{
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
    Notifier.broadcast("story:#{story_id}", "generation_progress", %{
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
