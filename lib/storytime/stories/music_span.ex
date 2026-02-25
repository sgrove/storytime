defmodule Storytime.Stories.MusicSpan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "music_spans" do
    field :start_page_index, :integer
    field :end_page_index, :integer
    field :loop, :boolean, default: true

    belongs_to :track, Storytime.Stories.MusicTrack, foreign_key: :track_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(span, attrs) do
    span
    |> cast(attrs, [:track_id, :start_page_index, :end_page_index, :loop])
    |> validate_required([:track_id, :start_page_index, :end_page_index])
    |> foreign_key_constraint(:track_id)
  end
end
