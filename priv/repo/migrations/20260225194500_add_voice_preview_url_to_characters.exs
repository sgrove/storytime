defmodule Storytime.Repo.Migrations.AddVoicePreviewUrlToCharacters do
  use Ecto.Migration

  def change do
    alter table(:characters) do
      add(:voice_preview_url, :string)
    end
  end
end
