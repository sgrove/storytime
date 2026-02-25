defmodule Storytime.StoryPack do
  @moduledoc """
  Minimal StoryPack assembler scaffold.

  This returns a deterministic placeholder payload until persistence and
  generation pipelines are wired.
  """

  @spec build(String.t()) :: map()
  def build(story_id) do
    %{
      schemaVersion: 1,
      slug: "story-#{story_id}",
      title: "Storytime Placeholder",
      characters: [],
      pages: [
        %{
          id: "page-1",
          pageIndex: 0,
          scene: %{
            kind: "scene",
            width: 1536,
            height: 1024,
            alt: "Placeholder scene"
          },
          narration: "Storytime bootstrap is live.",
          dialogue: []
        }
      ],
      music: %{tracks: [], spans: []}
    }
  end
end
