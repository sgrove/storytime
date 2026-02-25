defmodule Storytime.Stories.Page do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "pages" do
    field :page_index, :integer
    field :scene_description, :string
    field :narration_text, :string
    field :scene_image_url, :string
    field :narration_audio_url, :string
    field :narration_timings_url, :string
    field :sort_order, :integer, default: 0

    belongs_to :story, Storytime.Stories.Story
    has_many :dialogue_lines, Storytime.Stories.DialogueLine

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :story_id,
      :page_index,
      :scene_description,
      :narration_text,
      :scene_image_url,
      :narration_audio_url,
      :narration_timings_url,
      :sort_order
    ])
    |> validate_required([:story_id, :page_index])
    |> foreign_key_constraint(:story_id)
  end
end
