defmodule Storytime.Deploy.RenderDeploy do
  @moduledoc """
  Render Public API client for per-story static site provisioning.
  """

  @api_base "https://api.render.com/v1"
  @subdomain_regex ~r/^[a-z0-9](?:[a-z0-9-]{1,40}[a-z0-9])?$/
  @service_name_prefix "storytime-"

  @spec create_story_site(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_story_site(story, subdomain) when is_map(story) and is_binary(subdomain) do
    with :ok <- validate_subdomain(subdomain),
         {:ok, api_key} <- fetch_api_key(),
         {:ok, services} <- list_services(api_key),
         {:ok, template} <- resolve_template_service(services),
         payload <- create_payload(story, subdomain, template),
         {:ok, result} <- upsert_service(api_key, services, payload, story),
         {:ok, final_url} <- ensure_url(result) do
      {:ok, %{site_id: result.service_id, deploy_id: result.deploy_id, url: final_url}}
    end
  end

  @spec preflight_story_site(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def preflight_story_site(story, subdomain) when is_map(story) and is_binary(subdomain) do
    story_id = story_field(story, :id)
    target_name = service_name(subdomain)

    with :ok <- validate_subdomain(subdomain),
         {:ok, api_key} <- fetch_api_key(),
         {:ok, services} <- list_services(api_key) do
      case find_static_service_by_name(services, target_name) do
        nil ->
          {:ok,
           %{
             subdomain: subdomain,
             service_name: target_name,
             availability: :available,
             available: true
           }}

        %{"id" => service_id} = service ->
          with {:ok, env_vars} <- fetch_service_env_vars(api_key, service_id) do
            owner_story_id = owner_story_id_from_env_vars(env_vars)
            availability = availability_for_story(owner_story_id, story_id)

            {:ok,
             %{
               subdomain: subdomain,
               service_name: target_name,
               service_id: service_id,
               service_slug: service["slug"],
               owner_story_id: owner_story_id,
               availability: availability,
               available: availability == :owned
             }}
          end

        _service ->
          {:error, :render_service_shape_invalid}
      end
    end
  end

  defp validate_subdomain(subdomain) do
    if Regex.match?(@subdomain_regex, subdomain) do
      :ok
    else
      {:error, :invalid_subdomain}
    end
  end

  defp fetch_api_key do
    case System.get_env("RENDER_API_KEY") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_render_api_key}
    end
  end

  defp list_services(api_key) do
    case Req.get("#{@api_base}/services?limit=100", headers: auth_headers(api_key)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, Enum.map(body, &Map.get(&1, "service")) |> Enum.reject(&is_nil/1)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:render_list_services_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_template_service(services) do
    configured_id = System.get_env("RENDER_READER_TEMPLATE_SERVICE_ID")

    cond do
      is_binary(configured_id) and configured_id != "" ->
        case Enum.find(services, &(&1["id"] == configured_id and &1["type"] == "static_site")) do
          nil -> {:error, :reader_template_not_found}
          service -> {:ok, service}
        end

      true ->
        case Enum.find(services, fn service ->
               service["type"] == "static_site" and
                 String.starts_with?(service["name"] || "", "storytime-reader-")
             end) do
          nil -> {:error, :reader_template_not_found}
          service -> {:ok, service}
        end
    end
  end

  defp create_payload(story, subdomain, template) do
    service_name = service_name(subdomain)

    %{
      "type" => "static_site",
      "name" => service_name,
      "ownerId" => template["ownerId"],
      "repo" => template["repo"],
      "branch" => template["branch"],
      "rootDir" => template["rootDir"] || "",
      "autoDeploy" => "yes",
      "envVars" => env_vars(story),
      "serviceDetails" => %{
        "buildCommand" => runtime_config_build_command(),
        "publishPath" => get_in(template, ["serviceDetails", "publishPath"]) || "reader",
        "pullRequestPreviewsEnabled" => "no",
        "routes" => [
          %{"type" => "rewrite", "source" => "/*", "destination" => "/index.html"}
        ]
      }
    }
  end

  defp upsert_service(api_key, services, payload, story) do
    target_name = payload["name"]

    case find_static_service_by_name(services, target_name) do
      nil -> create_service(api_key, payload)
      service -> update_existing(api_key, service, payload, story)
    end
  end

  defp create_service(api_key, payload) do
    case Req.post("#{@api_base}/services", headers: auth_headers(api_key), json: payload) do
      {:ok, %{status: 201, body: %{"service" => service} = body}} ->
        deploy_id = body["deployId"]
        service_id = service["id"]

        with {:ok, _} <- maybe_wait_for_deploy(api_key, service_id, deploy_id) do
          {:ok,
           %{
             service_id: service_id,
             deploy_id: deploy_id,
             slug: service["slug"],
             url: get_in(service, ["serviceDetails", "url"])
           }}
        end

      {:ok, %{status: 409}} ->
        {:error, :subdomain_taken}

      {:ok, %{status: status, body: body}} ->
        {:error, {:render_create_service_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing(api_key, service, payload, story) do
    service_id = service["id"]
    story_id = story_field(story, :id)

    with {:ok, current_env_vars} <- fetch_service_env_vars(api_key, service_id),
         owner_story_id <- owner_story_id_from_env_vars(current_env_vars),
         :ok <- ensure_story_ownership(owner_story_id, story_id),
         :ok <- put_env_vars(api_key, service_id, payload["envVars"]),
         :ok <- patch_service_details(api_key, service_id, payload),
         {:ok, deploy_id} <- trigger_deploy(api_key, service_id),
         {:ok, _} <- maybe_wait_for_deploy(api_key, service_id, deploy_id) do
      {:ok,
       %{
         service_id: service_id,
         deploy_id: deploy_id,
         slug: service["slug"],
         url:
           get_in(service, ["serviceDetails", "url"]) || "https://#{service["slug"]}.onrender.com"
       }}
    end
  end

  defp patch_service_details(api_key, service_id, payload) do
    patch = %{
      "serviceDetails" => %{
        "buildCommand" =>
          get_in(payload, ["serviceDetails", "buildCommand"]) || runtime_config_build_command(),
        "publishPath" => get_in(payload, ["serviceDetails", "publishPath"]),
        "pullRequestPreviewsEnabled" => "no"
      }
    }

    case Req.patch("#{@api_base}/services/#{service_id}",
           headers: auth_headers(api_key),
           json: patch
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:render_patch_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_env_vars(api_key, service_id, env_vars) when is_list(env_vars) do
    case Req.put("#{@api_base}/services/#{service_id}/env-vars",
           headers: auth_headers(api_key),
           json: env_vars
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:render_env_vars_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_service_env_vars(api_key, service_id) do
    case Req.get("#{@api_base}/services/#{service_id}/env-vars", headers: auth_headers(api_key)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:render_env_vars_read_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trigger_deploy(api_key, service_id) do
    case Req.post("#{@api_base}/services/#{service_id}/deploys",
           headers: auth_headers(api_key),
           json: %{"clearCache" => "do_not_clear"}
         ) do
      {:ok, %{status: status, body: body}} when status in [201, 202] ->
        deploy_id = body["id"] || body["deploy"]["id"]

        if is_binary(deploy_id) do
          {:ok, deploy_id}
        else
          {:error, {:render_deploy_id_missing, body}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:render_trigger_deploy_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_wait_for_deploy(_api_key, _service_id, nil), do: {:ok, :no_deploy_id}

  defp maybe_wait_for_deploy(api_key, service_id, deploy_id) do
    wait_for_deploy(api_key, service_id, deploy_id, 80)
  end

  defp wait_for_deploy(_api_key, _service_id, _deploy_id, 0), do: {:error, :deploy_timeout}

  defp wait_for_deploy(api_key, service_id, deploy_id, attempts_left) do
    case Req.get("#{@api_base}/services/#{service_id}/deploys/#{deploy_id}",
           headers: auth_headers(api_key)
         ) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, deploy} <- unwrap_deploy(body) do
          case classify_deploy_status(Map.get(deploy, "status")) do
            :live ->
              {:ok, :live}

            :failed ->
              {:error, {:deploy_failed, deploy}}

            :pending ->
              Process.sleep(2500)
              wait_for_deploy(api_key, service_id, deploy_id, attempts_left - 1)

            :invalid ->
              {:error, {:deploy_status_invalid_status, body}}
          end
        else
          {:error, :invalid_deploy_response} ->
            {:error, {:deploy_status_invalid_shape, body}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:deploy_status_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec unwrap_deploy(term()) :: {:ok, map()} | {:error, :invalid_deploy_response}
  def unwrap_deploy(%{"deploy" => deploy}) when is_map(deploy), do: {:ok, deploy}
  def unwrap_deploy(%{"status" => _status} = deploy), do: {:ok, deploy}
  def unwrap_deploy(_), do: {:error, :invalid_deploy_response}

  @doc false
  @spec classify_deploy_status(term()) :: :live | :failed | :pending | :invalid
  def classify_deploy_status("live"), do: :live
  def classify_deploy_status("deployed"), do: :live
  def classify_deploy_status("succeeded"), do: :live

  def classify_deploy_status(status)
      when status in [
             "build_failed",
             "failed",
             "update_failed",
             "canceled",
             "cancelled",
             "deactivated",
             "pre_deploy_failed",
             "timed_out",
             "timeout",
             "build_timed_out",
             "deploy_failed"
           ] do
    :failed
  end

  def classify_deploy_status(status) when is_binary(status) and status != "", do: :pending
  def classify_deploy_status(_), do: :invalid

  @doc false
  @spec owner_story_id_from_env_vars(term()) :: String.t() | nil
  def owner_story_id_from_env_vars(env_vars) when is_list(env_vars) do
    env_map =
      env_vars
      |> Enum.reduce(%{}, fn row, acc ->
        env = if is_map(row), do: Map.get(row, "envVar", row), else: nil

        if is_map(env) and is_binary(env["key"]) do
          Map.put(acc, env["key"], env["value"])
        else
          acc
        end
      end)

    first_present([
      Map.get(env_map, "STORYTIME_STORY_ID"),
      Map.get(env_map, "VITE_STORY_ID")
    ])
  end

  def owner_story_id_from_env_vars(_), do: nil

  @doc false
  @spec availability_for_story(String.t() | nil, String.t() | nil) :: :owned | :taken
  def availability_for_story(nil, _story_id), do: :taken

  def availability_for_story(owner_story_id, story_id)
      when is_binary(owner_story_id) and is_binary(story_id) do
    if owner_story_id == story_id, do: :owned, else: :taken
  end

  def availability_for_story(_owner_story_id, _story_id), do: :taken

  defp ensure_url(%{url: url}) when is_binary(url) and url != "", do: {:ok, url}

  defp ensure_url(%{slug: slug}) when is_binary(slug) and slug != "" do
    {:ok, "https://#{slug}.onrender.com"}
  end

  defp ensure_url(%{service_id: service_id}) do
    {:ok, "https://#{service_id}.onrender.com"}
  end

  defp env_vars(story) do
    base_url = StorytimeWeb.Endpoint.url()
    story_id = story_field(story, :id) || ""
    story_slug = story_field(story, :slug) || ""

    [
      %{"key" => "VITE_API_HTTP_URL", "value" => base_url},
      %{"key" => "VITE_STORY_ID", "value" => story_id},
      %{"key" => "VITE_STORY_SLUG", "value" => story_slug},
      %{"key" => "VITE_STORY_PACK_URL", "value" => "#{base_url}/api/stories/#{story_id}/pack"},
      %{"key" => "VITE_INSTANT_APP_ID", "value" => System.get_env("INSTANT_APP_ID") || ""},
      %{"key" => "VITE_READER_ALLOW_PACK_OVERRIDE", "value" => "false"},
      %{"key" => "STORYTIME_STORY_ID", "value" => story_id},
      %{"key" => "STORYTIME_STORY_SLUG", "value" => story_slug}
    ]
  end

  defp auth_headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]
  end

  defp runtime_config_build_command do
    ~s(bash -lc 'mkdir -p reader && printf "{\\"apiBase\\":\\"%s\\",\\"storyId\\":\\"%s\\",\\"storySlug\\":\\"%s\\",\\"packUrl\\":\\"%s\\",\\"instantAppId\\":\\"%s\\",\\"allowPackOverride\\":%s}\\n" "$VITE_API_HTTP_URL" "$VITE_STORY_ID" "$VITE_STORY_SLUG" "$VITE_STORY_PACK_URL" "$VITE_INSTANT_APP_ID" "${VITE_READER_ALLOW_PACK_OVERRIDE:-false}" | tee reader/runtime-config.json runtime-config.json >/dev/null')
  end

  defp service_name(subdomain), do: "#{@service_name_prefix}#{subdomain}"

  defp find_static_service_by_name(services, service_name) do
    Enum.find(services, &(&1["name"] == service_name and &1["type"] == "static_site"))
  end

  defp ensure_story_ownership(owner_story_id, story_id)
       when is_binary(owner_story_id) and is_binary(story_id) do
    if owner_story_id == story_id, do: :ok, else: {:error, :subdomain_taken}
  end

  defp ensure_story_ownership(_owner_story_id, _story_id), do: {:error, :subdomain_taken}

  defp story_field(story, key) when is_map(story) and is_atom(key) do
    Map.get(story, key) || Map.get(story, Atom.to_string(key))
  end

  defp first_present(values) when is_list(values) do
    Enum.find(values, &(is_binary(&1) and &1 != ""))
  end
end
