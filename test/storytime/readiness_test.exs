defmodule Storytime.ReadinessTest do
  use ExUnit.Case, async: true

  alias Storytime.Readiness

  test "evaluate marks complete story as ready" do
    story = %{
      characters: [
        %{
          id: "char-1",
          name: "Luna",
          voice_id: "voice-1",
          headshot_url: "/assets/story/headshot_char-1.png",
          sort_order: 0
        }
      ],
      pages: [
        %{
          id: "page-1",
          page_index: 0,
          scene_description: "Moonlight in the garden",
          narration_text: "Luna tiptoed through the flowers.",
          scene_image_url: "/assets/story/scene_page-1.png",
          narration_audio_url: "/assets/story/narration_page-1.mp3",
          narration_timings_url: "/assets/story/narration_page-1_timings.json",
          dialogue_lines: [
            %{
              id: "line-1",
              character_id: "char-1",
              text: "What a peaceful night.",
              audio_url: "/assets/story/dialogue_line-1.mp3",
              timings_url: "/assets/story/dialogue_line-1_timings.json",
              sort_order: 0
            }
          ]
        }
      ],
      music_tracks: [
        %{
          id: "track-1",
          title: "Moonlight",
          mood: "gentle",
          audio_url: "/assets/story/music_track-1.mp3"
        }
      ]
    }

    readiness = Readiness.evaluate(story)

    assert readiness.ready == true
    assert readiness.blocking_count == 0
    assert readiness.auto_fixable_count == 0
    assert readiness.manual_count == 0
    assert readiness.items == []
  end

  test "evaluate emits auto-fix items for missing generated assets" do
    story = %{
      characters: [
        %{id: "char-1", name: "Luna", voice_id: "voice-1", headshot_url: nil, sort_order: 0}
      ],
      pages: [
        %{
          id: "page-1",
          page_index: 0,
          scene_description: "A bright workshop",
          narration_text: "The teams looked around nervously.",
          scene_image_url: nil,
          narration_audio_url: nil,
          narration_timings_url: nil,
          dialogue_lines: []
        }
      ],
      music_tracks: [%{id: "track-1", title: "Tension", mood: "anxious", audio_url: nil}]
    }

    readiness = Readiness.evaluate(story)

    assert readiness.ready == false
    assert readiness.blocking_count >= 5
    assert readiness.auto_fixable_count >= 5

    by_code =
      readiness.items
      |> Enum.group_by(& &1.code)

    assert Enum.any?(by_code["missing_headshot"], &(&1.action[:event] == "generate_headshot"))
    assert Enum.any?(by_code["missing_scene_image"], &(&1.action[:event] == "generate_scene"))

    assert Enum.any?(
             by_code["missing_narration_assets"],
             &(&1.action[:event] == "generate_narration_audio")
           )

    assert Enum.any?(by_code["missing_dialogue"], &(&1.action[:event] == "generate_dialogue"))
    assert Enum.any?(by_code["missing_music_audio"], &(&1.action[:event] == "generate_music"))
  end

  test "evaluate emits manual blockers when generation prerequisites are missing" do
    story = %{
      characters: [
        %{id: "char-1", name: "Luna", voice_id: nil, headshot_url: nil, sort_order: 0}
      ],
      pages: [
        %{
          id: "page-1",
          page_index: 0,
          scene_description: "",
          narration_text: "",
          scene_image_url: nil,
          narration_audio_url: nil,
          narration_timings_url: nil,
          dialogue_lines: [
            %{
              id: "line-1",
              character_id: "char-1",
              text: "  ",
              audio_url: nil,
              timings_url: nil,
              sort_order: 0
            }
          ]
        }
      ],
      music_tracks: []
    }

    readiness = Readiness.evaluate(story)

    assert readiness.ready == false
    assert readiness.manual_count >= 1

    assert Enum.any?(readiness.items, fn item ->
             item.code == "missing_character_voice" and item.auto_fixable == false
           end)

    assert Enum.any?(readiness.items, fn item ->
             item.code == "missing_narration_text" and item.auto_fixable == false
           end)

    assert Enum.any?(readiness.items, fn item ->
             item.code == "missing_dialogue_text" and item.auto_fixable == false
           end)
  end
end
