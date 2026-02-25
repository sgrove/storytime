defmodule Storytime.Workers.TtsGenWorker do
  @moduledoc """
  Generates page voice mix audio/timings (narration + dialogue) and keeps
  dialogue line playback mapped to a single per-page audio file.
  """

  use Oban.Worker, queue: :generation, max_attempts: 6

  alias Storytime.Assets
  alias Storytime.Notifier
  alias Storytime.Stories
  alias Storytime.WordTimings
  alias Storytime.Workers.DialogueGenWorker

  @default_narrator_voice_id "Xb7hH8MSUJpSbSDYk0k2"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    do_perform(args)
  rescue
    exception ->
      handle_failure(args, {:unhandled_exception, Exception.message(exception)})
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  @doc false
  def reusable_audio_urls(type, item, args) do
    if force_payload?(args) do
      :none
    else
      existing_audio_urls(type, item)
    end
  end

  @doc false
  def force_payload?(args) when is_map(args) do
    payload = Map.get(args, "payload") || Map.get(args, :payload) || %{}

    Map.get(payload, "force") in [true, "true", 1, "1"] or
      Map.get(payload, :force) in [true, "true", 1, "1"]
  end

  def force_payload?(_args), do: false

  @doc false
  def preserve_timings_payload?(args) when is_map(args) do
    payload = Map.get(args, "payload") || Map.get(args, :payload) || %{}

    Map.get(payload, "preserve_timings") in [true, "true", 1, "1"] or
      Map.get(payload, :preserve_timings) in [true, "true", 1, "1"]
  end

  def preserve_timings_payload?(_args), do: false

  defp do_perform(args) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, type} <- required_arg(args, "type"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, item} <- fetch_target(story, type, target_id) do
      case reusable_audio_urls(type, item, args) do
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
          with {:ok, page} <- page_for_target(type, item),
               {:ok, inputs} <- page_voice_inputs(page, story),
               :ok <- mark_running(generation_job_id),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 10),
               {:ok, audio_bytes, alignment, segments, provider} <- synthesize_page_voice(inputs),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 75),
               {:ok, audio_url, target_timings_url} <-
                 persist_page_voice_mix(story_id, page, inputs, audio_bytes, alignment, segments),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 95),
               :ok <- mark_completed(generation_job_id) do
            _ = Stories.maybe_mark_story_ready(story_id)
            broadcast_progress(story_id, type, target_id, generation_job_id, 100)

            Notifier.broadcast("story:#{story_id}", "generation_completed", %{
              story_id: story_id,
              job_type: map_job_type(type),
              target_id: target_id,
              job_id: generation_job_id,
              url: audio_url,
              timings_url: target_timings_url,
              page_id: page.id,
              provider: provider,
              page_voice_mix: true,
              reused: false
            })

            {:ok,
             %{
               url: audio_url,
               timings_url: target_timings_url,
               provider: provider,
               page_voice_mix: true
             }}
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

    case Enum.find_value(story.pages || [], fn page ->
           case Enum.find(page.dialogue_lines || [], &(&1.id == target_id)) do
             nil ->
               nil

             line ->
               line_with_character = %{
                 line
                 | character: Map.get(character_by_id, line.character_id)
               }

               %{
                 line: line_with_character,
                 page: page,
                 audio_url: line.audio_url,
                 timings_url: line.timings_url
               }
           end
         end) do
      nil -> {:error, :dialogue_not_found}
      result -> {:ok, result}
    end
  end

  defp fetch_target(story, "narration", target_id) do
    case Enum.find(story.pages, &(&1.id == target_id)) do
      nil -> {:error, :page_not_found}
      page -> {:ok, page}
    end
  end

  defp fetch_target(_story, _type, _target_id), do: {:error, :unsupported_tts_type}

  defp page_for_target("narration", page), do: {:ok, page}
  defp page_for_target("dialogue", %{page: page}) when is_map(page), do: {:ok, page}
  defp page_for_target(_type, _item), do: {:error, :unsupported_tts_type}

  defp page_voice_inputs(page, story) do
    narration_text = String.trim(to_string(page.narration_text || ""))
    character_by_id = Map.new(story.characters || [], &{&1.id, &1})

    dialogue_inputs =
      page.dialogue_lines
      |> List.wrap()
      |> Enum.sort_by(fn line -> {line.sort_order || 0, line.id || ""} end)
      |> Enum.reduce_while([], fn line, acc ->
        text = String.trim(to_string(line.text || ""))

        cond do
          text == "" ->
            {:cont, acc}

          true ->
            character = Map.get(character_by_id, line.character_id)
            voice_id = character && character.voice_id

            if blank?(voice_id) do
              {:halt, {:error, :missing_character_voice_id}}
            else
              {:cont,
               [
                 %{
                   kind: :dialogue,
                   line_id: line.id,
                   text: text,
                   voice_id: voice_id
                 }
                 | acc
               ]}
            end
        end
      end)

    with {:ok, dialogue_entries} <- normalize_dialogue_entries(dialogue_inputs) do
      entries =
        if narration_text == "" do
          dialogue_entries
        else
          [
            %{
              kind: :narration,
              page_id: page.id,
              text: narration_text,
              voice_id: default_voice_id()
            }
            | dialogue_entries
          ]
        end

      if entries == [] do
        {:error, :empty_text}
      else
        {:ok, entries}
      end
    end
  end

  defp normalize_dialogue_entries({:error, reason}), do: {:error, reason}
  defp normalize_dialogue_entries(entries) when is_list(entries), do: {:ok, Enum.reverse(entries)}

  defp synthesize_page_voice(entries) do
    api_key = System.get_env("ELEVENLABS_API_KEY")

    if blank?(api_key) do
      {:error, :missing_elevenlabs_api_key}
    else
      inputs = Enum.map(entries, fn entry -> {entry.voice_id, entry.text} end)

      with {:ok, payload} <- DialogueGenWorker.request_dialogue_timestamps_live(api_key, inputs),
           {:ok, audio_bytes} <- extract_dialogue_audio_bytes(payload),
           {:ok, alignment} <- extract_character_alignment(payload),
           {:ok, segments} <- extract_voice_segments(payload) do
        {:ok, audio_bytes, alignment, segments, "elevenlabs_dialogue"}
      end
    end
  end

  defp extract_dialogue_audio_bytes(%{"audio_base64" => audio_b64}) when is_binary(audio_b64) do
    case Base.decode64(audio_b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_audio_payload}
    end
  end

  defp extract_dialogue_audio_bytes(_payload), do: {:error, :invalid_audio_payload}

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

  defp persist_page_voice_mix(story_id, page, entries, audio_bytes, alignment, segments) do
    audio_filename = "narration_#{page.id}.mp3"

    with {:ok, audio_url} <- Assets.write_binary(story_id, audio_filename, audio_bytes),
         {:ok, narration_timings_url} <-
           persist_page_voice_entries(story_id, page, entries, audio_url, alignment, segments),
         {:ok, _} <-
           Stories.set_page_narration(story_id, page.id, audio_url, narration_timings_url) do
      {:ok, audio_url, narration_timings_url}
    end
  end

  defp persist_page_voice_entries(story_id, page, entries, audio_url, alignment, segments) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil}, fn {entry, input_index}, {:ok, narration_timings_url} ->
      with {:ok, range} <- dialogue_char_range_for_input(input_index, segments),
           {:ok, sliced_alignment, audio_start_ms, audio_end_ms} <-
             slice_alignment_range(alignment, range),
           timing_payload <-
             timing_payload(entry.text, sliced_alignment, audio_start_ms, audio_end_ms),
           {:ok, timing_url} <- write_entry_timings(story_id, page, entry, timing_payload),
           {:ok, next_narration_url} <-
             persist_entry_audio_mapping(
               story_id,
               entry,
               audio_url,
               timing_url,
               narration_timings_url
             ) do
        {:cont, {:ok, next_narration_url}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, narration_timings_url}
      when is_binary(narration_timings_url) and narration_timings_url != "" ->
        {:ok, narration_timings_url}

      {:ok, _} ->
        {:error, :missing_narration_timing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_entry_timings(story_id, page, %{kind: :narration}, payload) do
    filename = "narration_#{page.id}_timings.json"
    Assets.write_json(story_id, filename, payload)
  end

  defp write_entry_timings(story_id, _page, %{kind: :dialogue, line_id: line_id}, payload) do
    filename = "dialogue_#{line_id}_timings.json"
    Assets.write_json(story_id, filename, payload)
  end

  defp persist_entry_audio_mapping(
         _story_id,
         %{kind: :narration},
         _audio_url,
         timing_url,
         _narration_timings_url
       ) do
    {:ok, timing_url}
  end

  defp persist_entry_audio_mapping(
         story_id,
         %{kind: :dialogue, line_id: line_id},
         audio_url,
         timing_url,
         narration_timings_url
       ) do
    with {:ok, _} <- Stories.set_dialogue_audio(story_id, line_id, audio_url, timing_url) do
      {:ok, narration_timings_url}
    end
  end

  defp timing_payload(text, sliced_alignment, audio_start_ms, audio_end_ms) do
    WordTimings.from_alignment(text || "", sliced_alignment)
    |> Map.put("audioStartMs", audio_start_ms)
    |> Map.put("audioEndMs", audio_end_ms)
    |> Map.put("sharedAudio", true)
  end

  defp dialogue_char_range_for_input(input_index, segments) do
    matching =
      segments
      |> Enum.filter(&(segment_dialogue_input_index(&1) == input_index))
      |> Enum.map(fn segment ->
        {segment_integer(segment, "character_start_index"),
         segment_integer(segment, "character_end_index")}
      end)

    case matching do
      [] ->
        case Enum.at(segments, input_index) do
          segment when is_map(segment) ->
            start_idx = segment_integer(segment, "character_start_index")
            end_idx = segment_integer(segment, "character_end_index")

            if is_integer(start_idx) and is_integer(end_idx) and start_idx >= 0 and
                 end_idx > start_idx do
              {:ok, %{start_index: start_idx, end_index: end_idx}}
            else
              {:error, {:missing_dialogue_segment_for_index, input_index}}
            end

          _ ->
            {:error, {:missing_dialogue_segment_for_index, input_index}}
        end

      values ->
        start_idx = values |> Enum.map(&elem(&1, 0)) |> Enum.min()
        end_idx = values |> Enum.map(&elem(&1, 1)) |> Enum.max()

        if is_integer(start_idx) and is_integer(end_idx) and start_idx >= 0 and
             end_idx > start_idx do
          {:ok, %{start_index: start_idx, end_index: end_idx}}
        else
          {:error, {:invalid_dialogue_segment_range, input_index}}
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
        base_end = List.last(slice_ends) || base_start

        local_starts = Enum.map(slice_starts, &max(&1 - base_start, 0.0))
        local_ends = Enum.map(slice_ends, &max(&1 - base_start, 0.0))

        {:ok,
         %{
           "character_start_times_seconds" => local_starts,
           "character_end_times_seconds" => local_ends
         }, round(base_start * 1000), round(base_end * 1000)}
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

  @doc false
  def should_reuse_timings?("dialogue", line, args) when is_map(line) do
    preserve_timings_payload?(args) and not blank?(Map.get(line, :timings_url))
  end

  def should_reuse_timings?(_type, _line, _args), do: false

  @doc false
  def default_voice_id do
    env_voice = System.get_env("ELEVENLABS_DEFAULT_VOICE_ID")
    if blank?(env_voice), do: @default_narrator_voice_id, else: env_voice
  end

  @doc false
  def resolve_voice_id(voice_id) do
    if blank?(voice_id), do: default_voice_id(), else: voice_id
  end

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

      Notifier.broadcast("story:#{story_id}", "generation_completed", %{
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
      {:error, :not_found} -> :ok
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

      Notifier.broadcast("story:#{story_id}", "generation_failed", %{
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

      Notifier.broadcast("story:#{story_id}", "generation_completed", %{
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
  def non_retryable_reason?(:invalid_dialogue_alignment), do: true
  def non_retryable_reason?(:invalid_dialogue_voice_segments), do: true
  def non_retryable_reason?(:missing_narration_timing), do: true
  def non_retryable_reason?(:dialogue_alignment_range_out_of_bounds), do: true
  def non_retryable_reason?({:missing_arg, _key}), do: true
  def non_retryable_reason?({:missing_dialogue_segment_for_index, _index}), do: true
  def non_retryable_reason?({:invalid_dialogue_segment_range, _index}), do: true
  def non_retryable_reason?(:empty_dialogue_inputs), do: true
  def non_retryable_reason?(:invalid_dialogue_inputs), do: true
  def non_retryable_reason?(:invalid_dialogue_input), do: true
  def non_retryable_reason?(:invalid_dialogue_input_voice_id), do: true
  def non_retryable_reason?(:invalid_dialogue_input_text), do: true
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
    Notifier.broadcast("story:#{story_id}", "generation_progress", %{
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

  defp to_seconds(value) when is_integer(value), do: value * 1.0
  defp to_seconds(value) when is_float(value), do: value

  defp to_seconds(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp to_seconds(_value), do: 0.0
end
