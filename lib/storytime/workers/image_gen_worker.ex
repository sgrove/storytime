defmodule Storytime.Workers.ImageGenWorker do
  @moduledoc """
  Generates scene/headshot images via OpenAI Images API with deterministic
  filesystem pathing.
  """

  use Oban.Worker, queue: :generation, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Stories

  @openai_url "https://api.openai.com/v1/images/generations"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, type} <- required_arg(args, "type"),
         {:ok, target_id} <- required_arg(args, "target_id"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, target_prompt, filename} <- prompt_and_filename(story, type, target_id),
         :ok <- mark_running(generation_job_id),
         {:ok, image_bytes, provider} <- generate_image(target_prompt, image_size(type)),
         {:ok, asset_url} <- Assets.write_binary(story_id, filename, image_bytes),
         {:ok, _} <- persist_url(story_id, type, target_id, asset_url),
         :ok <- mark_completed(generation_job_id) do
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

  def perform(args) when is_map(args) do
    perform(%Oban.Job{args: args})
  end

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

  defp image_size("headshot"), do: "512x512"
  defp image_size("scene"), do: "1536x1024"

  defp generate_image(prompt, size) do
    case call_openai_image(prompt, size) do
      {:ok, bytes} ->
        {:ok, bytes, "openai"}

      {:error, _reason} = error ->
        if fallback_enabled?() do
          {:ok, Assets.tiny_png(), "fallback"}
        else
          error
        end
    end
  end

  defp call_openai_image(prompt, size) do
    api_key = System.get_env("OPENAI_API_KEY")

    if blank?(api_key) do
      {:error, :missing_openai_api_key}
    else
      body = %{
        model: "gpt-image-1.5",
        prompt: prompt,
        size: size,
        output_format: "png"
      }

      headers = [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]

      case Req.post(@openai_url, json: body, headers: headers) do
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
  end

  defp persist_url(story_id, "headshot", target_id, url), do: Stories.set_character_headshot(story_id, target_id, url)
  defp persist_url(story_id, "scene", target_id, url), do: Stories.set_page_scene(story_id, target_id, url)
  defp persist_url(_story_id, _type, _target_id, _url), do: {:error, :unsupported_image_type}

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

  defp map_job_type("headshot"), do: "headshot"
  defp map_job_type("scene"), do: "scene"
  defp map_job_type(_), do: "scene"

  defp required_arg(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  defp fallback_enabled? do
    String.downcase(System.get_env("GENERATION_FALLBACK", "true")) in ["1", "true", "yes"]
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
