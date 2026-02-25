defmodule Storytime.Deploy.RenderDeploy do
  @moduledoc """
  Render Public API client for per-story static site provisioning.
  """

  @api_base "https://api.render.com/v1"

  @spec create_story_site(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_story_site(story, subdomain) when is_map(story) and is_binary(subdomain) do
    with :ok <- validate_subdomain(subdomain),
         {:ok, api_key} <- fetch_api_key(),
         {:ok, services} <- list_services(api_key),
         {:ok, template} <- resolve_template_service(services),
         payload <- create_payload(story, subdomain, template),
         {:ok, result} <- upsert_service(api_key, services, payload, subdomain),
         {:ok, final_url} <- ensure_url(result) do
      {:ok, %{site_id: result.service_id, deploy_id: result.deploy_id, url: final_url}}
    end
  end

  defp validate_subdomain(subdomain) do
    if Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]{1,40}[a-z0-9])?$/, subdomain) do
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
    service_name = "storytime-#{subdomain}"

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

  defp upsert_service(api_key, services, payload, subdomain) do
    target_name = payload["name"]

    case Enum.find(services, &(&1["name"] == target_name and &1["type"] == "static_site")) do
      nil -> create_service(api_key, payload)
      service -> update_existing(api_key, service, payload, subdomain)
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

      {:ok, %{status: status, body: body}} ->
        {:error, {:render_create_service_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_existing(api_key, service, payload, _subdomain) do
    service_id = service["id"]

    with :ok <- put_env_vars(api_key, service_id, payload["envVars"]),
         :ok <- patch_service_details(api_key, service_id, payload),
         {:ok, deploy_id} <- trigger_deploy(api_key, service_id),
         {:ok, _} <- maybe_wait_for_deploy(api_key, service_id, deploy_id) do
      {:ok,
       %{
         service_id: service_id,
         deploy_id: deploy_id,
         slug: service["slug"],
         url: get_in(service, ["serviceDetails", "url"]) || "https://#{service["slug"]}.onrender.com"
       }}
    end
  end

  defp patch_service_details(api_key, service_id, payload) do
    patch = %{
      "serviceDetails" => %{
        "buildCommand" => get_in(payload, ["serviceDetails", "buildCommand"]) || runtime_config_build_command(),
        "publishPath" => get_in(payload, ["serviceDetails", "publishPath"]),
        "routes" => get_in(payload, ["serviceDetails", "routes"]),
        "pullRequestPreviewsEnabled" => "no"
      }
    }

    case Req.patch("#{@api_base}/services/#{service_id}", headers: auth_headers(api_key), json: patch) do
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
    case Req.get("#{@api_base}/services/#{service_id}/deploys/#{deploy_id}", headers: auth_headers(api_key)) do
      {:ok, %{status: 200, body: %{"deploy" => deploy}}} ->
        case deploy["status"] do
          "live" -> {:ok, :live}
          "build_failed" -> {:error, {:deploy_failed, deploy}}
          "canceled" -> {:error, {:deploy_canceled, deploy}}
          _ ->
            Process.sleep(2500)
            wait_for_deploy(api_key, service_id, deploy_id, attempts_left - 1)
        end

      {:ok, %{status: status, body: body}} -> {:error, {:deploy_status_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_url(%{url: url} = result) when is_binary(url) and url != "", do: {:ok, url}

  defp ensure_url(%{slug: slug}) when is_binary(slug) and slug != "" do
    {:ok, "https://#{slug}.onrender.com"}
  end

  defp ensure_url(%{service_id: service_id}) do
    {:ok, "https://#{service_id}.onrender.com"}
  end

  defp env_vars(story) do
    base_url = StorytimeWeb.Endpoint.url()

    [
      %{"key" => "VITE_API_HTTP_URL", "value" => base_url},
      %{"key" => "VITE_STORY_ID", "value" => story.id},
      %{"key" => "VITE_STORY_SLUG", "value" => story.slug},
      %{"key" => "VITE_STORY_PACK_URL", "value" => "#{base_url}/api/stories/#{story.id}/pack"},
      %{"key" => "VITE_INSTANT_APP_ID", "value" => System.get_env("INSTANT_APP_ID") || ""}
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
    ~s|bash -lc 'printf "{\\"apiBase\\":\\"%s\\",\\"storyId\\":\\"%s\\",\\"storySlug\\":\\"%s\\",\\"packUrl\\":\\"%s\\",\\"instantAppId\\":\\"%s\\"}\\n" "$VITE_API_HTTP_URL" "$VITE_STORY_ID" "$VITE_STORY_SLUG" "$VITE_STORY_PACK_URL" "$VITE_INSTANT_APP_ID" > reader/runtime-config.json'|
  end
end
