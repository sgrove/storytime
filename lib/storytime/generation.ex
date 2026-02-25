defmodule Storytime.Generation do
  @moduledoc """
  Oban-backed generation/deploy orchestration.
  """

  alias Storytime.Stories

  alias Storytime.Workers.{
    DeployWorker,
    DialogueGenWorker,
    ImageGenWorker,
    MusicGenWorker,
    TtsGenWorker
  }

  @subdomain_regex ~r/^[a-z0-9](?:[a-z0-9-]{1,40}[a-z0-9])?$/
  @max_jobs_per_request_default 25

  @spec enqueue(String.t(), atom(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def enqueue(story_id, generation_type, target_id, payload \\ %{}) do
    with {:ok, jobs} <- jobs_for_request(story_id, generation_type, target_id),
         :ok <- validate_job_count(jobs),
         :ok <- validate_jobs(story_id, generation_type, jobs),
         {:ok, first_job} <- persist_and_enqueue(story_id, jobs, payload) do
      _ = Stories.set_story_status(story_id, :generating)
      {:ok, first_job}
    end
  end

  @spec retry(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def retry(story_id, generation_job_id, payload \\ %{}) do
    case Stories.get_story_generation_job(story_id, generation_job_id) do
      nil ->
        {:error, :not_found}

      %{job_type: :deploy} ->
        {:error, :retry_not_supported}

      %{job_type: job_type, target_id: target_id} ->
        enqueue(story_id, job_type, target_id, Map.put(payload || %{}, "force", true))
    end
  end

  @spec delete(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(story_id, generation_job_id) do
    case Stories.get_story_generation_job(story_id, generation_job_id) do
      nil ->
        {:error, :not_found}

      generation_job ->
        oban_jobs = Stories.list_generation_oban_jobs(story_id, generation_job_id)
        cancelled_oban_job_ids = cancel_active_oban_jobs(oban_jobs)

        with {:ok, deleted_oban_jobs} <-
               Stories.delete_generation_oban_jobs(story_id, generation_job_id),
             {:ok, _} <- Stories.delete_generation_job(story_id, generation_job_id),
             {:ok, _} <- Stories.maybe_mark_story_ready(story_id) do
          {:ok,
           %{
             job_id: generation_job_id,
             deleted: true,
             stopped: cancelled_oban_job_ids != [],
             cancelled_oban_job_ids: cancelled_oban_job_ids,
             deleted_oban_jobs: deleted_oban_jobs,
             deleted_status: to_string(generation_job.status)
           }}
        end
    end
  end

  @spec enqueue_deploy(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def enqueue_deploy(story_id, subdomain, payload \\ %{}) do
    with :ok <- validate_subdomain(subdomain),
         :ok <- validate_deploy_story(story_id),
         {:ok, gen_job} <- Stories.create_generation_job(story_id, :deploy, nil),
         {:ok, _oban_job} <-
           %{
             "generation_job_id" => gen_job.id,
             "story_id" => story_id,
             "payload" => Map.put(payload || %{}, "subdomain", subdomain)
           }
           |> DeployWorker.new(queue: :deploy, max_attempts: 5)
           |> Oban.insert(),
         {:ok, _} <- Stories.set_story_status(story_id, :generating) do
      {:ok, gen_job}
    end
  end

  defp jobs_for_request(_story_id, :headshot, target_id), do: single(:headshot, target_id)
  defp jobs_for_request(_story_id, :scene, target_id), do: single(:scene, target_id)
  defp jobs_for_request(_story_id, :dialogue, target_id), do: single(:dialogue, target_id)
  defp jobs_for_request(_story_id, :dialogue_tts, target_id), do: single(:dialogue_tts, target_id)

  defp jobs_for_request(_story_id, :narration_tts, target_id),
    do: single(:narration_tts, target_id)

  defp jobs_for_request(_story_id, :music, target_id), do: single(:music, target_id)

  defp jobs_for_request(story_id, :all_scenes, _target_id) do
    with story when not is_nil(story) <- Stories.load_story_graph(story_id) do
      jobs =
        Enum.flat_map(story.characters, fn c ->
          if blank?(c.headshot_url), do: [{:headshot, c.id}], else: []
        end) ++
          Enum.flat_map(story.pages, fn p ->
            if blank?(p.scene_image_url), do: [{:scene, p.id}], else: []
          end)

      wrap_jobs(jobs)
    else
      _ -> {:error, :not_found}
    end
  end

  defp jobs_for_request(story_id, :all_audio, _target_id) do
    with story when not is_nil(story) <- Stories.load_story_graph(story_id) do
      jobs =
        Enum.flat_map(story.pages, fn p ->
          narration =
            if blank?(p.narration_audio_url) and text_present?(p.narration_text),
              do: [{:narration_tts, p.id}],
              else: []

          dialogue =
            Enum.flat_map(p.dialogue_lines, fn line ->
              if blank?(line.audio_url) and text_present?(line.text),
                do: [{:dialogue_tts, line.id}],
                else: []
            end)

          narration ++ dialogue
        end)

      wrap_jobs(jobs)
    else
      _ -> {:error, :not_found}
    end
  end

  defp jobs_for_request(story_id, :all_dialogue, _target_id) do
    with story when not is_nil(story) <- Stories.load_story_graph(story_id),
         true <- has_voiced_characters?(story) do
      jobs =
        Enum.flat_map(story.pages, fn page ->
          if Enum.empty?(page.dialogue_lines || []), do: [{:dialogue, page.id}], else: []
        end)

      wrap_jobs(jobs)
    else
      false -> {:error, :nothing_to_generate}
      _ -> {:error, :not_found}
    end
  end

  defp jobs_for_request(story_id, :all, _target_id) do
    with story when not is_nil(story) <- Stories.load_story_graph(story_id),
         {:ok, scenes} <- optional_jobs(story_id, :all_scenes),
         {:ok, dialogue} <- optional_jobs(story_id, :all_dialogue),
         {:ok, audio} <- optional_jobs(story_id, :all_audio) do
      music =
        Enum.flat_map(story.music_tracks, fn track ->
          if blank?(track.audio_url), do: [{:music, track.id}], else: []
        end)

      wrap_jobs(scenes ++ dialogue ++ audio ++ music)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp jobs_for_request(_story_id, _generation_type, _target_id),
    do: {:error, :unsupported_job_type}

  defp single(_job_type, nil), do: {:error, :missing_target_id}
  defp single(job_type, target_id), do: {:ok, [{job_type, target_id}]}

  defp wrap_jobs([]), do: {:error, :nothing_to_generate}
  defp wrap_jobs(jobs), do: {:ok, jobs}

  @doc false
  def max_jobs_per_request do
    case Integer.parse(System.get_env("GENERATION_MAX_JOBS_PER_REQUEST") || "") do
      {value, ""} when value > 0 -> value
      _ -> @max_jobs_per_request_default
    end
  end

  @doc false
  def validate_job_count(jobs, limit \\ max_jobs_per_request()) when is_list(jobs) do
    if length(jobs) > limit do
      {:error, :too_many_jobs_requested}
    else
      :ok
    end
  end

  defp validate_jobs(_story_id, generation_type, _jobs)
       when generation_type in [:all_scenes, :all_audio, :all_dialogue, :all],
       do: :ok

  defp validate_jobs(story_id, _generation_type, [{job_type, target_id}]) do
    case Stories.load_story_graph(story_id) do
      nil -> {:error, :not_found}
      story -> validate_single_job(story, job_type, target_id)
    end
  end

  defp validate_jobs(_story_id, _generation_type, _jobs), do: :ok

  @doc false
  def validate_single_job(story, :headshot, target_id) do
    if Enum.any?(story.characters || [], &(&1.id == target_id)) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  def validate_single_job(story, :scene, target_id) do
    if Enum.any?(story.pages || [], &(&1.id == target_id)) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  def validate_single_job(story, :dialogue, target_id) do
    if Enum.any?(story.pages || [], &(&1.id == target_id)) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  def validate_single_job(story, :music, target_id) do
    if Enum.any?(story.music_tracks || [], &(&1.id == target_id)) do
      :ok
    else
      {:error, :invalid_target}
    end
  end

  def validate_single_job(story, :dialogue_tts, target_id) do
    with {:ok, line} <- find_dialogue_line(story, target_id),
         true <- text_present?(line.text) or {:error, :empty_text},
         {:ok, character} <- find_character(story, line.character_id),
         true <- not blank?(character.voice_id) or {:error, :missing_character_voice_id} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_single_job(story, :narration_tts, target_id) do
    with {:ok, page} <- find_page(story, target_id),
         true <- text_present?(page.narration_text) or {:error, :empty_text} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  def validate_single_job(_story, _job_type, _target_id), do: :ok

  defp persist_and_enqueue(story_id, jobs, payload) do
    jobs
    |> Enum.map(fn {job_type, target_id} ->
      maybe_enqueue_job(story_id, job_type, target_id, payload)
    end)
    |> collect_created_jobs([])
    |> case do
      {:ok, created_jobs} -> {:ok, List.first(created_jobs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_enqueue_job(story_id, job_type, target_id, payload) do
    case active_job_for(story_id, job_type, target_id, payload) do
      nil ->
        with {:ok, gen_job} <- Stories.create_generation_job(story_id, job_type, target_id),
             {:ok, _oban_job} <-
               insert_oban_job(story_id, gen_job.id, job_type, target_id, payload) do
          {:ok, gen_job}
        end

      active_job ->
        {:ok, active_job}
    end
  end

  defp active_job_for(story_id, job_type, target_id, payload) do
    if force_payload?(payload) do
      nil
    else
      Stories.find_active_generation_job(story_id, job_type, target_id)
    end
  end

  defp force_payload?(payload) when is_map(payload) do
    Map.get(payload, "force") in [true, "true", 1, "1"] or
      Map.get(payload, :force) in [true, "true", 1, "1"]
  end

  defp force_payload?(_payload), do: false

  defp insert_oban_job(story_id, generation_job_id, :headshot, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "type" => "headshot",
      "target_id" => target_id,
      "payload" => payload
    }
    |> ImageGenWorker.new(queue: :generation, max_attempts: 5)
    |> Oban.insert()
  end

  defp insert_oban_job(story_id, generation_job_id, :scene, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "type" => "scene",
      "target_id" => target_id,
      "payload" => payload
    }
    |> ImageGenWorker.new(queue: :generation, max_attempts: 5)
    |> Oban.insert()
  end

  defp insert_oban_job(story_id, generation_job_id, :dialogue_tts, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "type" => "dialogue",
      "target_id" => target_id,
      "payload" => payload
    }
    |> TtsGenWorker.new(queue: :generation, max_attempts: 6)
    |> Oban.insert()
  end

  defp insert_oban_job(story_id, generation_job_id, :dialogue, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "target_id" => target_id,
      "payload" => payload
    }
    |> DialogueGenWorker.new(queue: :generation, max_attempts: 4)
    |> Oban.insert()
  end

  defp insert_oban_job(story_id, generation_job_id, :narration_tts, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "type" => "narration",
      "target_id" => target_id,
      "payload" => payload
    }
    |> TtsGenWorker.new(queue: :generation, max_attempts: 6)
    |> Oban.insert()
  end

  defp insert_oban_job(story_id, generation_job_id, :music, target_id, payload) do
    %{
      "generation_job_id" => generation_job_id,
      "story_id" => story_id,
      "target_id" => target_id,
      "payload" => payload
    }
    |> MusicGenWorker.new(queue: :generation, max_attempts: 5)
    |> Oban.insert()
  end

  defp collect_created_jobs([], acc), do: {:ok, Enum.reverse(acc)}
  defp collect_created_jobs([{:ok, job} | tail], acc), do: collect_created_jobs(tail, [job | acc])
  defp collect_created_jobs([{:error, reason} | _tail], _acc), do: {:error, reason}

  defp cancel_active_oban_jobs(oban_jobs) do
    oban_jobs
    |> Enum.filter(&active_oban_job?/1)
    |> Enum.map(fn oban_job ->
      _ = Oban.cancel_job(oban_job.id)
      oban_job.id
    end)
  end

  defp active_oban_job?(%{state: state}) do
    state = state |> to_string() |> String.downcase()
    state in ["available", "scheduled", "retryable", "executing"]
  end

  defp active_oban_job?(_), do: false

  defp blank?(value), do: value in [nil, ""]

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false

  defp find_page(story, page_id) do
    case Enum.find(story.pages || [], &(&1.id == page_id)) do
      nil -> {:error, :invalid_target}
      page -> {:ok, page}
    end
  end

  defp find_character(story, character_id) do
    case Enum.find(story.characters || [], &(&1.id == character_id)) do
      nil -> {:error, :invalid_target}
      character -> {:ok, character}
    end
  end

  defp find_dialogue_line(story, line_id) do
    line =
      story.pages
      |> List.wrap()
      |> Enum.flat_map(&List.wrap(&1.dialogue_lines))
      |> Enum.find(&(&1.id == line_id))

    if line, do: {:ok, line}, else: {:error, :invalid_target}
  end

  defp has_voiced_characters?(story) do
    Enum.any?(story.characters || [], fn character -> not blank?(character.voice_id) end)
  end

  defp optional_jobs(story_id, generation_type) do
    case jobs_for_request(story_id, generation_type, nil) do
      {:ok, jobs} -> {:ok, jobs}
      {:error, :nothing_to_generate} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_subdomain(subdomain) when is_binary(subdomain) do
    if Regex.match?(@subdomain_regex, subdomain) do
      :ok
    else
      {:error, :invalid_subdomain}
    end
  end

  defp validate_subdomain(_), do: {:error, :invalid_subdomain}

  defp validate_deploy_story(story_id) do
    case Stories.load_story_graph(story_id) do
      nil ->
        {:error, :not_found}

      story ->
        if Enum.empty?(story.pages || []) do
          {:error, :story_missing_content}
        else
          :ok
        end
    end
  end
end
