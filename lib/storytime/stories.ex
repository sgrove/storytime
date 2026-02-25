defmodule Storytime.Stories do
  @moduledoc """
  Story domain context scaffold.

  Persistence and channel-backed mutations will be implemented in the next phase.
  """

  def get_story(_id), do: {:error, :not_implemented}
  def list_characters(_story_id), do: []
  def list_pages(_story_id), do: []
  def list_music_tracks(_story_id), do: []
end
