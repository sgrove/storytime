defmodule Storytime.Stories.Story do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:draft, :generating, :ready, :deployed]

  schema "stories" do
    field :title, :string
    field :slug, :string
    field :art_style, :string
    field :status, Ecto.Enum, values: @statuses, default: :draft
    field :deploy_url, :string
    field :render_site_id, :string

    has_many :characters, Storytime.Stories.Character
    has_many :pages, Storytime.Stories.Page
    has_many :music_tracks, Storytime.Stories.MusicTrack
    has_many :generation_jobs, Storytime.Stories.GenerationJob

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(story, attrs) do
    story
    |> cast(attrs, [:title, :slug, :art_style, :status, :deploy_url, :render_site_id])
    |> validate_required([:title, :slug])
    |> unique_constraint(:slug)
  end
end
