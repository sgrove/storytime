defmodule Storytime.Stories.MusicTrack do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "music_tracks" do
    field :title, :string
    field :mood, :string
    field :audio_url, :string

    belongs_to :story, Storytime.Stories.Story
    has_many :music_spans, Storytime.Stories.MusicSpan, foreign_key: :track_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(track, attrs) do
    track
    |> cast(attrs, [:story_id, :title, :mood, :audio_url])
    |> validate_required([:story_id, :title])
    |> foreign_key_constraint(:story_id)
  end
end
