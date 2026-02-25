defmodule StorytimeWeb.StoryChannelContractTest do
  use ExUnit.Case, async: true

  alias StorytimeWeb.StoryChannel

  @fr011_required_client_events [
    "update_story",
    "add_character",
    "update_character",
    "delete_character",
    "add_page",
    "update_page",
    "reorder_pages",
    "delete_page",
    "add_dialogue_line",
    "update_dialogue_line",
    "delete_dialogue_line",
    "generate_headshot",
    "generate_scene",
    "generate_all_scenes",
    "generate_dialogue_audio",
    "generate_all_audio",
    "generate_music",
    "generate_all",
    "deploy_story"
  ]

  @fr012_required_broadcast_events [
    "story_updated",
    "character_added",
    "page_updated",
    "generation_started",
    "generation_progress",
    "generation_completed",
    "generation_failed",
    "deploy_started",
    "deploy_completed",
    "deploy_failed"
  ]

  test "FR-011 required client events are declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()

    for event <- @fr011_required_client_events do
      assert MapSet.member?(declared, event), "missing required client event #{event}"
    end
  end

  test "FR-012 required broadcast events are declared" do
    declared = StoryChannel.required_broadcast_events() |> MapSet.new()

    for event <- @fr012_required_broadcast_events do
      assert MapSet.member?(declared, event), "missing required broadcast event #{event}"
    end
  end

  test "extended client event for dialogue generation is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "generate_dialogue")
    assert MapSet.member?(declared, "generate_all_dialogue")
  end
end
