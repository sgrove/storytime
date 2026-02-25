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
    "delete_generation_job",
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

  @fr012_required_payload_keys %{
    "story_updated" => ["story"],
    "character_added" => ["character"],
    "page_updated" => ["page"],
    "generation_started" => ["job_type", "target_id"],
    "generation_progress" => ["job_type", "target_id", "progress"],
    "generation_completed" => ["job_type", "target_id"],
    "generation_failed" => ["job_type", "target_id", "error"],
    "deploy_started" => [],
    "deploy_completed" => ["url"],
    "deploy_failed" => ["error"]
  }

  @channel_broadcast_payload_keys %{
    "story_updated" => ["story"],
    "character_added" => ["character"],
    "character_updated" => ["character"],
    "character_deleted" => ["id", "character"],
    "page_added" => ["page"],
    "page_updated" => ["page"],
    "page_deleted" => ["id", "page"],
    "pages_reordered" => ["pages"],
    "dialogue_line_added" => ["line"],
    "dialogue_line_updated" => ["line"],
    "dialogue_line_deleted" => ["id", "line"],
    "music_track_added" => ["track"],
    "music_track_updated" => ["track"],
    "music_track_deleted" => ["id", "track"],
    "music_span_added" => ["span"],
    "music_span_updated" => ["span"],
    "music_span_deleted" => ["id", "span"],
    "generation_started" => ["story_id", "job_type", "target_id", "job_id"],
    "generation_deleted" => ["story_id", "job_id", "deleted"],
    "deploy_started" => ["story_id", "job_id"]
  }

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

  test "FR-012 required broadcast payload keys are declared" do
    declared = StoryChannel.required_broadcast_payload_keys()

    for {event, required_keys} <- @fr012_required_payload_keys do
      declared_keys = Map.get(declared, event, [])

      for key <- required_keys do
        assert key in declared_keys,
               "missing required payload key #{key} for broadcast event #{event}"
      end
    end
  end

  test "channel broadcast payload contract is declared for all channel-emitted events" do
    declared = StoryChannel.channel_broadcast_payload_keys()

    for {event, required_keys} <- @channel_broadcast_payload_keys do
      declared_keys = Map.get(declared, event, [])

      for key <- required_keys do
        assert key in declared_keys,
               "missing channel payload key #{key} for broadcast event #{event}"
      end
    end
  end

  test "declared payload key lists do not contain duplicates" do
    contracts =
      StoryChannel.required_broadcast_payload_keys()
      |> Map.merge(StoryChannel.channel_broadcast_payload_keys())

    for {event, keys} <- contracts do
      assert Enum.uniq(keys) == keys,
             "duplicate payload keys declared for event #{event}"
    end
  end

  test "extended client event for dialogue generation is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "generate_dialogue")
    assert MapSet.member?(declared, "generate_all_dialogue")
  end

  test "extended client event for generation retry is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "retry_generation")
  end

  test "extended client event for generation history pruning is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "prune_generation_jobs")
  end

  test "extended client event for generation deletion is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "delete_generation_job")
  end

  test "extended client event for deploy preflight is declared" do
    declared = StoryChannel.required_client_events() |> MapSet.new()
    assert MapSet.member?(declared, "deploy_preflight")
  end
end
