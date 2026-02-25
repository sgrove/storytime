defmodule Storytime.Repo.Migrations.CreateStorytimeCoreTables do
  use Ecto.Migration

  def change do
    create table(:stories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :slug, :string, null: false
      add :art_style, :string
      add :status, :string, null: false, default: "draft"
      add :deploy_url, :string
      add :render_site_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:stories, [:slug])

    create table(:characters, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :visual_description, :text
      add :voice_provider, :string
      add :voice_id, :string
      add :voice_model_id, :string
      add :headshot_url, :string
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:characters, [:story_id])

    create table(:pages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :page_index, :integer, null: false
      add :scene_description, :text
      add :narration_text, :text
      add :scene_image_url, :string
      add :narration_audio_url, :string
      add :narration_timings_url, :string
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pages, [:story_id])
    create index(:pages, [:story_id, :page_index])

    create table(:dialogue_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :page_id, references(:pages, type: :binary_id, on_delete: :delete_all), null: false
      add :character_id, references(:characters, type: :binary_id, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :audio_url, :string
      add :timings_url, :string
      add :sort_order, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:dialogue_lines, [:page_id])
    create index(:dialogue_lines, [:character_id])

    create table(:music_tracks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :mood, :string
      add :audio_url, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:music_tracks, [:story_id])

    create table(:music_spans, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :track_id, references(:music_tracks, type: :binary_id, on_delete: :delete_all), null: false
      add :start_page_index, :integer, null: false
      add :end_page_index, :integer, null: false
      add :loop, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:music_spans, [:track_id])

    create table(:generation_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :story_id, references(:stories, type: :binary_id, on_delete: :delete_all), null: false
      add :job_type, :string, null: false
      add :target_id, :binary_id
      add :status, :string, null: false, default: "pending"
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:generation_jobs, [:story_id])
    create index(:generation_jobs, [:status])
  end
end
