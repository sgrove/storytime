defmodule StorytimeWeb.ApiController do
  use StorytimeWeb, :controller

  alias Storytime.Stories

  def version(conn, _params) do
    json(conn, %{service: "storytime-api", phase: "phoenix-skeleton"})
  end

  def stories(conn, _params) do
    if repo_running?() do
      payload =
        Stories.list_stories()
        |> Enum.map(&story_json/1)

      json(conn, %{stories: payload})
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "database_unavailable"})
    end
  end

  def create_story(conn, params) do
    if repo_running?() do
      attrs = %{
        title: Map.get(params, "title", "Untitled Story"),
        art_style: Map.get(params, "art_style", "storybook watercolor"),
        slug: Map.get(params, "slug")
      }

      case Stories.create_story(attrs) do
        {:ok, story} ->
          conn
          |> put_status(:created)
          |> json(%{story: story_json(story)})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "validation_failed", details: format_errors(changeset)})
      end
    else
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "database_unavailable"})
    end
  end

  def story_pack(conn, %{"id" => id}) do
    payload = Storytime.StoryPack.build(id)
    json(conn, payload)
  end

  defp repo_running?, do: Process.whereis(Storytime.Repo) != nil

  defp story_json(story) do
    %{
      id: story.id,
      title: story.title,
      slug: story.slug,
      art_style: story.art_style,
      status: story.status
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
  end
end
