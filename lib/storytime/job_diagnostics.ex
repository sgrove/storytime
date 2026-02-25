defmodule Storytime.JobDiagnostics do
  @moduledoc """
  Enriches generation jobs with contextual target and Oban runtime diagnostics.
  """

  @running_stale_seconds_default 900
  @terminal_oban_states [:completed, :discarded, :cancelled, :canceled]
  @terminal_oban_states_strings Enum.map(@terminal_oban_states, &to_string/1)

  @spec enrich([map()], map() | nil, [map()], DateTime.t()) :: [map()]
  def enrich(generation_jobs, story, oban_jobs, now \\ DateTime.utc_now()) do
    oban_by_generation_job_id = build_oban_lookup(oban_jobs)
    target_context = build_target_context(story)
    pending_positions = pending_positions(generation_jobs)

    Enum.map(generation_jobs, fn job ->
      oban_job = Map.get(oban_by_generation_job_id, job.id)
      status = effective_status(job.status, oban_job)
      age_seconds = age_seconds(job, oban_job, status, now)
      running_stale_seconds = running_stale_seconds()
      likely_stuck = likely_stuck?(status, oban_job, age_seconds, running_stale_seconds)

      base = %{
        id: job.id,
        job_type: to_string(job.job_type),
        target_id: job.target_id,
        status: status,
        error: job.error,
        inserted_at: job.inserted_at,
        updated_at: job.updated_at,
        age_seconds: age_seconds,
        updated_seconds_ago: elapsed_seconds(job.updated_at, now),
        queue_position: queue_position(job, pending_positions),
        active_detail:
          active_detail(job, oban_job, pending_positions, now, status, age_seconds, likely_stuck),
        likely_stuck: likely_stuck,
        stale_after_seconds: if(status == "running", do: running_stale_seconds, else: nil)
      }

      base
      |> Map.merge(target_details(job, target_context))
      |> put_oban_details(oban_job, now)
    end)
  end

  defp build_oban_lookup(oban_jobs) do
    Enum.reduce(oban_jobs, %{}, fn oban_job, acc ->
      generation_job_id = get_arg(oban_job.args, "generation_job_id")

      cond do
        not is_binary(generation_job_id) or generation_job_id == "" ->
          acc

        Map.has_key?(acc, generation_job_id) ->
          acc

        true ->
          Map.put(acc, generation_job_id, oban_job)
      end
    end)
  end

  defp build_target_context(nil), do: %{characters: %{}, pages: %{}, dialogue: %{}, tracks: %{}}

  defp build_target_context(story) do
    characters = Map.new(story.characters || [], fn character -> {character.id, character} end)
    pages = Map.new(story.pages || [], fn page -> {page.id, page} end)
    tracks = Map.new(story.music_tracks || [], fn track -> {track.id, track} end)

    dialogue =
      Enum.reduce(story.pages || [], %{}, fn page, acc ->
        Enum.reduce(page.dialogue_lines || [], acc, fn line, inner_acc ->
          character = Map.get(characters, line.character_id)
          Map.put(inner_acc, line.id, %{line: line, page: page, character: character})
        end)
      end)

    %{characters: characters, pages: pages, dialogue: dialogue, tracks: tracks}
  end

  defp pending_positions(generation_jobs) do
    generation_jobs
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
    |> Enum.with_index(1)
    |> Map.new(fn {job, position} -> {job.id, position} end)
  end

  defp target_details(%{job_type: :headshot, target_id: target_id}, context) do
    case Map.get(context.characters, target_id) do
      nil ->
        %{}

      character ->
        %{
          target_label: "Character \"#{character.name}\"",
          character_id: character.id,
          character_name: character.name
        }
    end
  end

  defp target_details(%{job_type: :scene, target_id: target_id}, context) do
    case Map.get(context.pages, target_id) do
      nil ->
        %{}

      page ->
        scene_character_names = scene_character_names(page, context.characters)

        %{
          target_label: "Page #{page.page_index + 1} scene",
          page_id: page.id,
          page_index: page.page_index,
          page_number: page.page_index + 1,
          text_preview: clip(page.scene_description),
          scene_character_names: scene_character_names
        }
    end
  end

  defp target_details(%{job_type: :dialogue, target_id: target_id}, context) do
    case Map.get(context.pages, target_id) do
      nil ->
        %{}

      page ->
        %{
          target_label: "Page #{page.page_index + 1} dialogue",
          page_id: page.id,
          page_index: page.page_index,
          page_number: page.page_index + 1,
          text_preview: clip(page.narration_text)
        }
    end
  end

  defp target_details(%{job_type: :narration_tts, target_id: target_id}, context) do
    case Map.get(context.pages, target_id) do
      nil ->
        %{}

      page ->
        %{
          target_label: "Page #{page.page_index + 1} narration",
          page_id: page.id,
          page_index: page.page_index,
          page_number: page.page_index + 1,
          text_preview: clip(page.narration_text)
        }
    end
  end

  defp target_details(%{job_type: :dialogue_tts, target_id: target_id}, context) do
    case Map.get(context.dialogue, target_id) do
      nil ->
        %{}

      %{line: line, page: page, character: character} ->
        %{
          target_label: "Page #{page.page_index + 1} dialogue",
          page_id: page.id,
          page_index: page.page_index,
          page_number: page.page_index + 1,
          dialogue_line_id: line.id,
          character_id: line.character_id,
          character_name: if(character, do: character.name),
          text_preview: clip(line.text)
        }
    end
  end

  defp target_details(%{job_type: :music, target_id: target_id}, context) do
    case Map.get(context.tracks, target_id) do
      nil ->
        %{}

      track ->
        %{
          target_label: "Music track \"#{track.title}\"",
          music_track_id: track.id,
          text_preview: clip(track.mood)
        }
    end
  end

  defp target_details(%{job_type: :deploy}, _context), do: %{target_label: "Render deploy"}
  defp target_details(_job, _context), do: %{}

  defp put_oban_details(payload, nil, _now), do: payload

  defp put_oban_details(payload, oban_job, now) do
    errors = oban_job.errors || []

    oban = %{
      id: oban_job.id,
      state: to_string(oban_job.state),
      queue: oban_job.queue,
      worker: oban_job.worker,
      attempt: oban_job.attempt,
      max_attempts: oban_job.max_attempts,
      inserted_at: oban_job.inserted_at,
      scheduled_at: oban_job.scheduled_at,
      attempted_at: oban_job.attempted_at,
      completed_at: oban_job.completed_at,
      cancelled_at: oban_job.cancelled_at,
      discarded_at: oban_job.discarded_at,
      errors_count: length(errors),
      last_error: last_error(errors),
      available_in_seconds: seconds_until(oban_job.scheduled_at, now)
    }

    Map.put(payload, :oban, oban)
  end

  defp queue_position(%{status: :pending} = job, positions), do: Map.get(positions, job.id)
  defp queue_position(_job, _positions), do: nil

  defp active_detail(
         %{status: status} = job,
         oban_job,
         positions,
         now,
         effective_status,
         age_seconds,
         likely_stuck
       )
       when status in [:pending, :running] do
    oban_state = if(oban_job, do: to_string(oban_job.state), else: nil)

    cond do
      likely_stuck ->
        threshold = running_stale_seconds()

        "Running for about #{age_seconds}s (threshold #{threshold}s). Likely stuck; retry to enqueue a fresh attempt."

      status == :running and oban_state == "executing" ->
        "Worker is actively executing this job."

      status == :running and is_binary(oban_state) ->
        "Job marked running (oban: #{oban_state})."

      status == :pending and oban_state in ["discarded", "cancelled", "canceled"] ->
        "Worker exhausted retries. Retry this job to enqueue a fresh attempt."

      status == :pending and oban_state in ["scheduled", "retryable"] ->
        wait = seconds_until(oban_job.scheduled_at, now)

        if is_integer(wait) and wait > 0 do
          "Queued for retry in about #{wait}s."
        else
          "Queued for retry."
        end

      effective_status == "pending" and is_integer(Map.get(positions, job.id)) ->
        "Waiting in queue at position #{Map.get(positions, job.id)}."

      effective_status == "pending" ->
        "Queued and waiting for an available worker slot."

      true ->
        nil
    end
  end

  defp active_detail(_job, _oban_job, _positions, _now, _status, _age_seconds, _likely_stuck),
    do: nil

  defp get_arg(args, "generation_job_id") when is_map(args) do
    Map.get(args, "generation_job_id") || Map.get(args, :generation_job_id)
  end

  defp get_arg(args, key) when is_map(args), do: Map.get(args, key)

  defp get_arg(_args, _key), do: nil

  defp last_error([]), do: nil

  defp last_error(errors) when is_list(errors) do
    errors
    |> List.last()
    |> case do
      %{"error" => error} when is_binary(error) -> error
      %{error: error} when is_binary(error) -> error
      _ -> nil
    end
  end

  defp elapsed_seconds(nil, _now), do: nil

  defp elapsed_seconds(datetime, now) do
    DateTime.diff(now, datetime, :second)
  end

  defp age_seconds(%{inserted_at: nil}, _oban_job, _status, _now), do: nil

  defp age_seconds(%{inserted_at: inserted_at} = job, oban_job, status, now) do
    reference =
      if status in ["completed", "failed"] do
        terminal_reference(job, oban_job) || now
      else
        now
      end

    max(DateTime.diff(reference, inserted_at, :second), 0)
  end

  defp terminal_reference(job, oban_job) do
    [
      job.updated_at,
      oban_job && oban_job.completed_at,
      oban_job && oban_job.discarded_at,
      oban_job && oban_job.cancelled_at,
      oban_job && oban_job.attempted_at
    ]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] ->
        nil

      candidates ->
        Enum.max_by(candidates, &DateTime.to_unix(&1, :microsecond))
    end
  end

  defp likely_stuck?("running", oban_job, age_seconds, stale_seconds)
       when is_integer(age_seconds) and is_integer(stale_seconds) do
    age_seconds >= stale_seconds and running_oban_state?(oban_job)
  end

  defp likely_stuck?(_status, _oban_job, _age_seconds, _stale_seconds), do: false

  defp running_oban_state?(nil), do: true

  defp running_oban_state?(%{state: state}) when state in @terminal_oban_states, do: false

  defp running_oban_state?(%{state: state}) when is_binary(state) do
    state not in @terminal_oban_states_strings
  end

  defp running_oban_state?(_), do: true

  defp running_stale_seconds do
    case Integer.parse(System.get_env("GENERATION_RUNNING_STALE_SECONDS") || "") do
      {value, ""} when value >= 60 -> value
      _ -> @running_stale_seconds_default
    end
  end

  defp effective_status(:pending, %{state: state})
       when state in [:discarded, :cancelled, :canceled],
       do: "failed"

  defp effective_status(:pending, %{state: state})
       when state in ["discarded", "cancelled", "canceled"],
       do: "failed"

  defp effective_status(status, _oban_job), do: to_string(status)

  defp seconds_until(nil, _now), do: nil

  defp seconds_until(datetime, now) do
    max(DateTime.diff(datetime, now, :second), 0)
  end

  defp clip(nil), do: nil

  defp clip(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= 120 -> trimmed
      true -> String.slice(trimmed, 0, 117) <> "..."
    end
  end

  defp clip(value), do: clip(to_string(value))

  defp scene_character_names(page, characters_by_id) do
    page
    |> Map.get(:dialogue_lines, [])
    |> List.wrap()
    |> Enum.sort_by(fn line -> {line.sort_order || 0, line.id || ""} end)
    |> Enum.map(&Map.get(&1, :character_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn character_id ->
      case Map.get(characters_by_id, character_id) do
        nil -> nil
        character -> character.name
      end
    end)
    |> Enum.reject(fn name -> not is_binary(name) or String.trim(name) == "" end)
  end
end
