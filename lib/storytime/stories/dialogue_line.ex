defmodule Storytime.Stories.DialogueLine do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "dialogue_lines" do
    field :text, :string
    field :audio_url, :string
    field :timings_url, :string
    field :sort_order, :integer, default: 0

    belongs_to :page, Storytime.Stories.Page
    belongs_to :character, Storytime.Stories.Character

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(line, attrs) do
    line
    |> cast(attrs, [:page_id, :character_id, :text, :audio_url, :timings_url, :sort_order])
    |> validate_required([:page_id, :character_id, :text])
    |> foreign_key_constraint(:page_id)
    |> foreign_key_constraint(:character_id)
  end
end
