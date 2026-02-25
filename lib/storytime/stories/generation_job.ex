defmodule Storytime.Stories.GenerationJob do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @job_types [:headshot, :scene, :dialogue, :dialogue_tts, :narration_tts, :music, :deploy]
  @job_statuses [:pending, :running, :completed, :failed]

  schema "generation_jobs" do
    field(:job_type, Ecto.Enum, values: @job_types)
    field(:target_id, :binary_id)
    field(:status, Ecto.Enum, values: @job_statuses, default: :pending)
    field(:error, :string)

    belongs_to(:story, Storytime.Stories.Story)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [:story_id, :job_type, :target_id, :status, :error])
    |> validate_required([:story_id, :job_type, :status])
    |> foreign_key_constraint(:story_id)
  end
end
