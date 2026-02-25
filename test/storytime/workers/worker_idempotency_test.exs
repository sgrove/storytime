defmodule Storytime.Workers.WorkerIdempotencyTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.{ImageGenWorker, MusicGenWorker, TtsGenWorker}

  test "image worker detects reusable headshot and scene assets" do
    story = %{
      characters: [
        %{id: "char-1", headshot_url: "https://assets.example/headshot_char-1.png"},
        %{id: "char-2", headshot_url: nil}
      ],
      pages: [
        %{id: "page-1", scene_image_url: "https://assets.example/scene_page-1.png"},
        %{id: "page-2", scene_image_url: ""}
      ]
    }

    assert {:ok, "https://assets.example/headshot_char-1.png"} =
             ImageGenWorker.existing_asset_url(story, "headshot", "char-1")

    assert {:ok, "https://assets.example/scene_page-1.png"} =
             ImageGenWorker.existing_asset_url(story, "scene", "page-1")

    assert :none = ImageGenWorker.existing_asset_url(story, "headshot", "char-2")
    assert :none = ImageGenWorker.existing_asset_url(story, "scene", "page-2")
  end

  test "tts worker only reuses audio when both audio and timings are present" do
    dialogue_line = %{
      audio_url: "https://assets.example/dialogue.mp3",
      timings_url: "https://assets.example/dialogue_timings.json"
    }

    missing_timings = %{audio_url: "https://assets.example/dialogue.mp3", timings_url: nil}

    narration_page = %{
      narration_audio_url: "https://assets.example/narration.mp3",
      narration_timings_url: "https://assets.example/narration_timings.json"
    }

    assert {:ok, "https://assets.example/dialogue.mp3",
            "https://assets.example/dialogue_timings.json"} =
             TtsGenWorker.existing_audio_urls("dialogue", dialogue_line)

    assert :none = TtsGenWorker.existing_audio_urls("dialogue", missing_timings)

    assert {:ok, "https://assets.example/narration.mp3",
            "https://assets.example/narration_timings.json"} =
             TtsGenWorker.existing_audio_urls("narration", narration_page)
  end

  test "music worker detects reusable track audio" do
    assert {:ok, "https://assets.example/music_track.mp3"} =
             MusicGenWorker.existing_track_audio(%{
               audio_url: "https://assets.example/music_track.mp3"
             })

    assert :none = MusicGenWorker.existing_track_audio(%{audio_url: ""})
    assert :none = MusicGenWorker.existing_track_audio(%{audio_url: nil})
  end
end
