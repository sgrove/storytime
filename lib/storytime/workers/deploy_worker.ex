defmodule Storytime.Workers.DeployWorker do
  @moduledoc """
  Provisions/updates per-story reader static sites on Render.
  """

  use Oban.Worker, queue: :deploy, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Deploy.RenderDeploy
  alias Storytime.Stories
  alias Storytime.StoryPack

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, generation_job_id} <- required_arg(args, "generation_job_id"),
         {:ok, story_id} <- required_arg(args, "story_id"),
         {:ok, payload} <- required_map(args, "payload"),
         {:ok, subdomain} <- required_field(payload, "subdomain"),
         {:ok, story} <- fetch_story(story_id),
         {:ok, _} <- Stories.set_story_status(story_id, :generating),
         :ok <- status_update(generation_job_id, :running),
         :ok <- persist_story_json(story_id),
         {:ok, deploy} <- RenderDeploy.create_story_site(story, subdomain),
         {:ok, _story} <- Stories.mark_story_deployed(story_id, deploy.site_id, deploy.url),
         :ok <- status_update(generation_job_id, :completed) do
      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "deploy_completed", %{
        story_id: story_id,
        job_id: generation_job_id,
        url: deploy.url,
        render_site_id: deploy.site_id,
        deploy_id: deploy.deploy_id
      })

      {:ok, %{url: deploy.url, site_id: deploy.site_id, deploy_id: deploy.deploy_id}}
    else
      {:error, reason} ->
        handle_failure(args, reason)
    end
  end

  def perform(args) when is_map(args), do: perform(%Oban.Job{args: args})

  defp fetch_story(story_id) do
    case Stories.get_story(story_id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  defp persist_story_json(story_id) do
    case StoryPack.build(story_id) do
      {:ok, story_pack} ->
        case Assets.write_json(story_id, "story.json", story_pack) do
          {:ok, _url} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_update(job_id, status, error \\ nil) do
    case Stories.set_generation_job_status(job_id, status, error) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_failure(args, reason) do
    generation_job_id = Map.get(args, "generation_job_id")
    story_id = Map.get(args, "story_id")

    _ = status_update(generation_job_id, :failed, inspect(reason))
    if is_binary(story_id), do: Stories.set_story_status(story_id, :ready)

    if story_id do
      StorytimeWeb.Endpoint.broadcast("story:#{story_id}", "deploy_failed", %{
        story_id: story_id,
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

  defp required_map(args, key) do
    case Map.get(args, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:missing_map, key}}
    end
  end

  defp required_field(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_field, key}}
    end
  end
end
