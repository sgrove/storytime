defmodule Storytime.Stories.Character do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "characters" do
    field(:name, :string)
    field(:visual_description, :string)
    field(:voice_provider, :string)
    field(:voice_id, :string)
    field(:voice_model_id, :string)
    field(:headshot_url, :string)
    field(:voice_preview_url, :string)
    field(:sort_order, :integer, default: 0)

    belongs_to(:story, Storytime.Stories.Story)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(character, attrs) do
    character
    |> cast(attrs, [
      :story_id,
      :name,
      :visual_description,
      :voice_provider,
      :voice_id,
      :voice_model_id,
      :headshot_url,
      :voice_preview_url,
      :sort_order
    ])
    |> validate_required([:story_id, :name])
    |> foreign_key_constraint(:story_id)
  end
end
