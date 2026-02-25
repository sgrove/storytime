defmodule Storytime.Stories.Story do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :generating, :ready, :deployed]
  @slug_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  schema "stories" do
    field(:title, :string)
    field(:slug, :string)
    field(:art_style, :string)
    field(:status, Ecto.Enum, values: @statuses, default: :draft)
    field(:deploy_url, :string)
    field(:render_site_id, :string)

    has_many(:characters, Storytime.Stories.Character)
    has_many(:pages, Storytime.Stories.Page)
    has_many(:music_tracks, Storytime.Stories.MusicTrack)
    has_many(:generation_jobs, Storytime.Stories.GenerationJob)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(story, attrs) do
    story
    |> cast(attrs, [:title, :slug, :art_style, :status, :deploy_url, :render_site_id])
    |> normalize_slug()
    |> validate_required([:title, :slug])
    |> validate_length(:slug, min: 2, max: 64)
    |> validate_format(:slug, @slug_regex)
    |> unique_constraint(:slug)
  end

  defp normalize_slug(changeset) do
    update_change(changeset, :slug, fn
      value when is_binary(value) ->
        value
        |> String.trim()
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/u, "-")
        |> String.trim("-")

      value ->
        value
    end)
  end
end
