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

  @spec enqueue(String.t(), atom(), String.t() | nil, map()) :: {:ok, map()} | {:error, term()}
  def enqueue(story_id, generation_type, target_id, payload \\ %{}) do
    with {:ok, jobs} <- jobs_for_request(story_id, generation_type, target_id),
         {:ok, first_job} <- persist_and_enqueue(story_id, jobs, payload) do
      _ = Stories.set_story_status(story_id, :generating)
      {:ok, first_job}
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
          narration = if blank?(p.narration_audio_url), do: [{:narration_tts, p.id}], else: []

          dialogue =
            Enum.flat_map(p.dialogue_lines, fn line ->
              if blank?(line.audio_url), do: [{:dialogue_tts, line.id}], else: []
            end)

          narration ++ dialogue
        end)

      wrap_jobs(jobs)
    else
      _ -> {:error, :not_found}
    end
  end

  defp jobs_for_request(story_id, :all, _target_id) do
    with {:ok, scenes} <- jobs_for_request(story_id, :all_scenes, nil),
         {:ok, audio} <- jobs_for_request(story_id, :all_audio, nil),
         story when not is_nil(story) <- Stories.load_story_graph(story_id) do
      music =
        Enum.flat_map(story.music_tracks, fn track ->
          if blank?(track.audio_url), do: [{:music, track.id}], else: []
        end)

      wrap_jobs(scenes ++ audio ++ music)
    else
      {:error, :nothing_to_generate} -> {:error, :nothing_to_generate}
      _ -> {:error, :not_found}
    end
  end

  defp jobs_for_request(_story_id, _generation_type, _target_id),
    do: {:error, :unsupported_job_type}

  defp single(_job_type, nil), do: {:error, :missing_target_id}
  defp single(job_type, target_id), do: {:ok, [{job_type, target_id}]}

  defp wrap_jobs([]), do: {:error, :nothing_to_generate}
  defp wrap_jobs(jobs), do: {:ok, jobs}

  defp persist_and_enqueue(story_id, jobs, payload) do
    jobs
    |> Enum.map(fn {job_type, target_id} ->
      with {:ok, gen_job} <- Stories.create_generation_job(story_id, job_type, target_id),
           {:ok, _oban_job} <- insert_oban_job(story_id, gen_job.id, job_type, target_id, payload) do
        {:ok, gen_job}
      end
    end)
    |> collect_created_jobs([])
    |> case do
      {:ok, created_jobs} -> {:ok, List.first(created_jobs)}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp blank?(value), do: value in [nil, ""]

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
