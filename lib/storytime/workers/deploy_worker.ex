defmodule Storytime.Workers.DeployWorker do
  @moduledoc """
  Provisions/updates per-story reader static sites on Render.
  """

  use Oban.Worker, queue: :deploy, max_attempts: 5

  alias Storytime.Assets
  alias Storytime.Deploy.RenderDeploy
  alias Storytime.Notifier
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
      Notifier.broadcast("story:#{story_id}", "deploy_completed", %{
        story_id: story_id,
        job_id: generation_job_id,
        url: deploy.url,
        render_site_id: deploy.site_id,
        deploy_id: deploy.deploy_id
      })

      {:ok, %{url: deploy.url, site_id: deploy.site_id, deploy_id: deploy.deploy_id}}
    else
      {:error, reason} ->
        resolve_failure(args, reason)
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
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_failure(args, reason) do
    _ = handle_failure(args, reason)

    if non_retryable_reason?(reason) do
      {:discard, reason}
    else
      {:error, reason}
    end
  end

  defp handle_failure(args, reason) do
    generation_job_id = Map.get(args, "generation_job_id")
    story_id = Map.get(args, "story_id")
    details = failure_details(reason)

    _ = status_update(generation_job_id, :failed, inspect(reason))
    if is_binary(story_id), do: Stories.set_story_status(story_id, :ready)

    if story_id do
      Notifier.broadcast("story:#{story_id}", "deploy_failed", %{
        story_id: story_id,
        job_id: generation_job_id,
        error: details.message,
        error_code: details.code,
        error_category: details.category,
        retryable: details.retryable
      })
    end

    {:error, reason}
  end

  @doc false
  def non_retryable_reason?(:story_not_found), do: true
  def non_retryable_reason?(:invalid_subdomain), do: true
  def non_retryable_reason?(:reader_template_not_found), do: true
  def non_retryable_reason?(:missing_render_api_key), do: true
  def non_retryable_reason?({:missing_arg, _}), do: true
  def non_retryable_reason?({:missing_map, _}), do: true
  def non_retryable_reason?({:missing_field, _}), do: true

  def non_retryable_reason?({:render_list_services_failed, status, _}) when status in 400..499,
    do: true

  def non_retryable_reason?({:render_create_service_failed, status, _}) when status in 400..499,
    do: true

  def non_retryable_reason?({:render_env_vars_failed, status, _}) when status in 400..499,
    do: true

  def non_retryable_reason?({:render_patch_failed, status, _}) when status in 400..499, do: true

  def non_retryable_reason?({:render_trigger_deploy_failed, status, _}) when status in 400..499,
    do: true

  def non_retryable_reason?({:deploy_failed, _}), do: true
  def non_retryable_reason?(_), do: false

  @doc false
  def failure_details(reason) do
    category =
      cond do
        non_retryable_reason?(reason) -> "validation_or_configuration"
        reason == :deploy_timeout -> "timeout"
        true -> "transient_or_unknown"
      end

    %{
      message: inspect(reason),
      code: failure_code(reason),
      category: category,
      retryable: not non_retryable_reason?(reason)
    }
  end

  defp failure_code(reason) when is_atom(reason), do: to_string(reason)

  defp failure_code({code, _, _}) when is_atom(code), do: to_string(code)
  defp failure_code({code, _}) when is_atom(code), do: to_string(code)
  defp failure_code(_), do: "unknown"

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
