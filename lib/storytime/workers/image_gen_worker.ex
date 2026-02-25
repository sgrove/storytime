defmodule Storytime.Workers.ImageGenWorker do
  @moduledoc """
  Generates scene/headshot images via OpenAI Images API with deterministic
  filesystem pathing.
  """

  use Oban.Worker, queue: :generation, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Stories

  @openai_url "https://api.openai.com/v1/images/generations"
  @openai_image_model "gpt-image-1.5"
  @headshot_image_size "1024x1024"
  @scene_image_size "1536x1024"
  @openai_image_timeout_ms_default 300_000
  @openai_connect_timeout_ms_default 30_000
  @openai_pool_timeout_ms_default 120_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, type} <- required_arg(args, "type"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id) do
      case reusable_asset_url(story, type, target_id, args) do
        {:ok, asset_url} ->
          complete_from_cached(story_id, type, target_id, generation_job_id, asset_url)

        :none ->
          with {:ok, target_prompt, filename} <- prompt_and_filename(story, type, target_id),
               :ok <- mark_running(generation_job_id),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 10),
               {:ok, image_bytes, provider} <- generate_image(target_prompt, image_size_for(type)),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 75),
               {:ok, asset_url} <- Assets.write_binary(story_id, filename, image_bytes),
               {:ok, _} <- persist_url(story_id, type, target_id, asset_url),
               :ok <- emit_progress(story_id, type, target_id, generation_job_id, 95),
               :ok <- mark_completed(generation_job_id) do
            _ = Stories.maybe_mark_story_ready(story_id)
            broadcast_progress(story_id, type, target_id, generation_job_id, 100)

            StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
              story_id: story_id,
              job_type: map_job_type(type),
              target_id: target_id,
              job_id: generation_job_id,
              url: asset_url
            })

            {:ok, %{url: asset_url, provider: provider}}
          else
            {:error, reason} ->
              handle_failure(args, reason)
          end
      end
    else
      {:error, reason} ->
        handle_failure(args, reason)
    end
  end

  def perform(args) when is_map(args) do
    perform(%Oban.Job{args: args})
  end

  @doc false
  def reusable_asset_url(story, type, target_id, args) do
    if force_payload?(args) do
      :none
    else
      existing_asset_url(story, type, target_id)
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

  defp prompt_and_filename(story, "headshot", target_id) do
    case Enum.find(story.characters, &(&1.id == target_id)) do
      nil ->
        {:error, :character_not_found}

      character ->
        prompt =
          [
            "Children's storybook headshot.",
            "Art style: #{story.art_style || "storybook watercolor"}.",
            "Character: #{character.name}.",
            "Visual description: #{character.visual_description || ""}."
          ]
          |> Enum.join(" ")

        {:ok, prompt, "headshot_#{target_id}.png"}
    end
  end

  defp prompt_and_filename(story, "scene", target_id) do
    case Enum.find(story.pages, &(&1.id == target_id)) do
      nil ->
        {:error, :page_not_found}

      page ->
        prompt =
          [
            "Children's storybook landscape scene.",
            "Art style: #{story.art_style || "storybook watercolor"}.",
            "Scene description: #{page.scene_description || ""}.",
            "Narration context: #{page.narration_text || ""}."
          ]
          |> Enum.join(" ")

        {:ok, prompt, "scene_#{target_id}.png"}
    end
  end

  defp prompt_and_filename(_story, _type, _target_id), do: {:error, :unsupported_image_type}

  @doc false
  def image_size_for("headshot"), do: @headshot_image_size
  def image_size_for("scene"), do: @scene_image_size

  @doc false
  def openai_image_model, do: @openai_image_model

  @doc false
  def openai_image_timeout_ms do
    timeout_from_env(
      System.get_env("OPENAI_IMAGE_TIMEOUT_MS"),
      @openai_image_timeout_ms_default,
      30_000
    )
  end

  @doc false
  def openai_connect_timeout_ms do
    timeout_from_env(
      System.get_env("OPENAI_IMAGE_CONNECT_TIMEOUT_MS"),
      @openai_connect_timeout_ms_default,
      5_000
    )
  end

  @doc false
  def openai_pool_timeout_ms do
    timeout_from_env(
      System.get_env("OPENAI_IMAGE_POOL_TIMEOUT_MS"),
      @openai_pool_timeout_ms_default,
      5_000
    )
  end

  @doc false
  def timeout_from_env(raw_value, default_ms, min_ms)
      when is_binary(raw_value) and is_integer(default_ms) and is_integer(min_ms) do
    case Integer.parse(String.trim(raw_value)) do
      {value, ""} when value >= min_ms -> value
      _ -> default_ms
    end
  end

  def timeout_from_env(_raw_value, default_ms, _min_ms), do: default_ms

  defp generate_image(prompt, size) do
    case call_openai_image(prompt, size) do
      {:ok, bytes} -> {:ok, bytes, "openai"}
      {:error, _reason} = error -> error
    end
  end

  defp call_openai_image(prompt, size) do
    api_key = System.get_env("OPENAI_API_KEY")

    if blank?(api_key) do
      {:error, :missing_openai_api_key}
    else
      case request_openai_image(api_key, prompt, size) do
        {:ok, bytes} ->
          {:ok, bytes}

        {:error, {:openai_error, status, body} = error} ->
          if should_fallback_size?(status, body, size) do
            fallback_size = fallback_size_for(size)

            case request_openai_image(api_key, prompt, fallback_size) do
              {:ok, bytes} -> {:ok, bytes}
              {:error, _reason} -> {:error, error}
            end
          else
            {:error, error}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request_openai_image(api_key, prompt, size) do
    body = %{
      model: @openai_image_model,
      prompt: prompt,
      size: size,
      output_format: "png"
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.post(@openai_url,
           json: body,
           headers: headers,
           receive_timeout: openai_image_timeout_ms(),
           pool_timeout: openai_pool_timeout_ms(),
           connect_options: [timeout: openai_connect_timeout_ms()],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"data" => [%{"b64_json" => b64} | _]}}} ->
        case Base.decode64(b64) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_image_payload}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:openai_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def should_fallback_size?(400, body, size) when is_binary(size) do
    fallback_size_for(size) != nil and invalid_size_error?(body)
  end

  def should_fallback_size?(_status, _body, _size), do: false

  @doc false
  def fallback_size_for("512x512"), do: @headshot_image_size
  def fallback_size_for(_), do: nil

  defp invalid_size_error?(%{"error" => error}) when is_map(error) do
    code = Map.get(error, "code")
    param = Map.get(error, "param")
    message = Map.get(error, "message", "")

    code == "invalid_value" and param == "size" and
      is_binary(message) and String.contains?(String.downcase(message), "supported values")
  end

  defp invalid_size_error?(_), do: false

  defp persist_url(story_id, "headshot", target_id, url),
    do: Stories.set_character_headshot(story_id, target_id, url)

  defp persist_url(story_id, "scene", target_id, url),
    do: Stories.set_page_scene(story_id, target_id, url)

  defp persist_url(_story_id, _type, _target_id, _url), do: {:error, :unsupported_image_type}

  @doc false
  def existing_asset_url(story, "headshot", target_id) do
    case Enum.find(story.characters || [], &(&1.id == target_id and not blank?(&1.headshot_url))) do
      nil -> :none
      character -> {:ok, character.headshot_url}
    end
  end

  def existing_asset_url(story, "scene", target_id) do
    case Enum.find(story.pages || [], &(&1.id == target_id and not blank?(&1.scene_image_url))) do
      nil -> :none
      page -> {:ok, page.scene_image_url}
    end
  end

  def existing_asset_url(_story, _type, _target_id), do: :none

  defp complete_from_cached(story_id, type, target_id, generation_job_id, asset_url) do
    with :ok <- mark_completed(generation_job_id) do
      _ = Stories.maybe_mark_story_ready(story_id)
      broadcast_progress(story_id, type, target_id, generation_job_id, 100)

      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "generation_completed", %{
        story_id: story_id,
        job_type: map_job_type(type),
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

  defp handle_failure(args, reason) do
    generation_job_id = Map.get(args, "generation_job_id")
    story_id = Map.get(args, "story_id")
    type = Map.get(args, "type")
    target_id = Map.get(args, "target_id")

    _ = status_update(generation_job_id, :failed, inspect(reason))

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

  defp map_job_type("headshot"), do: "headshot"
  defp map_job_type("scene"), do: "scene"
  defp map_job_type(_), do: "scene"

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
