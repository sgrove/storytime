defmodule Storytime.Workers.MusicGenWorkerTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.MusicGenWorker

  test "extract_task_id supports common Sonauto response shapes" do
    assert "task-1" == MusicGenWorker.extract_task_id(%{"task_id" => "task-1"})
    assert "task-2" == MusicGenWorker.extract_task_id(%{"id" => "task-2"})
    assert "task-3" == MusicGenWorker.extract_task_id(%{"job_id" => "task-3"})
    assert nil == MusicGenWorker.extract_task_id(%{})
  end

  test "extract_audio_url supports common Sonauto completion payloads" do
    assert "https://cdn.example/song.mp3" ==
             MusicGenWorker.extract_audio_url(%{"song_path" => "https://cdn.example/song.mp3"})

    assert "https://cdn.example/song-list.mp3" ==
             MusicGenWorker.extract_audio_url(%{
               "song_paths" => ["https://cdn.example/song-list.mp3"]
             })

    assert "https://cdn.example/audio.mp3" ==
             MusicGenWorker.extract_audio_url(%{"audio_url" => "https://cdn.example/audio.mp3"})

    assert "https://cdn.example/url.mp3" ==
             MusicGenWorker.extract_audio_url(%{"url" => "https://cdn.example/url.mp3"})

    assert nil == MusicGenWorker.extract_audio_url(%{})
  end

  test "normalize_task_status handles pending/complete/failed values" do
    assert :pending == MusicGenWorker.normalize_task_status("processing")
    assert :pending == MusicGenWorker.normalize_task_status("queued")
    assert :complete == MusicGenWorker.normalize_task_status("complete")
    assert :complete == MusicGenWorker.normalize_task_status("succeeded")
    assert :complete == MusicGenWorker.normalize_task_status("SUCCESS")
    assert :failed == MusicGenWorker.normalize_task_status("failed")
    assert :failed == MusicGenWorker.normalize_task_status("cancelled")
  end

  test "non_retryable_reason identifies configuration and terminal provider errors" do
    assert MusicGenWorker.non_retryable_reason?(:missing_sonauto_api_key)
    assert MusicGenWorker.non_retryable_reason?(:track_not_found)
    assert MusicGenWorker.non_retryable_reason?({:sonauto_error, 422, %{}})
    assert MusicGenWorker.non_retryable_reason?({:sonauto_poll_error, 404, %{}})
    assert MusicGenWorker.non_retryable_reason?({:sonauto_failed, %{}})
    assert MusicGenWorker.non_retryable_reason?({:sonauto_stalled, "task-1"})

    refute MusicGenWorker.non_retryable_reason?(:sonauto_timeout)
    refute MusicGenWorker.non_retryable_reason?({:sonauto_timeout, :poll_elapsed})
    refute MusicGenWorker.non_retryable_reason?({:sonauto_error, 503, %{}})
  end

  test "force payload bypasses cached track audio reuse" do
    track = %{audio_url: "https://assets.example/music.mp3"}

    assert {:ok, "https://assets.example/music.mp3"} =
             MusicGenWorker.reusable_track_audio(track, %{"payload" => %{"force" => false}})

    assert :none =
             MusicGenWorker.reusable_track_audio(track, %{"payload" => %{"force" => true}})
  end

  test "force payload parser accepts boolean/string/integer truthy values" do
    assert MusicGenWorker.force_payload?(%{"payload" => %{"force" => true}})
    assert MusicGenWorker.force_payload?(%{"payload" => %{"force" => "true"}})
    assert MusicGenWorker.force_payload?(%{"payload" => %{"force" => 1}})
    refute MusicGenWorker.force_payload?(%{"payload" => %{"force" => false}})
    refute MusicGenWorker.force_payload?(%{"payload" => %{}})
  end

  test "invalid_tags_error detects Sonauto invalid-tag validation failures" do
    body = %{
      "detail" => [
        %{
          "msg" => "Value error, Invalid tags: background, storybook",
          "type" => "value_error"
        }
      ]
    }

    assert MusicGenWorker.invalid_tags_error?(body)
    refute MusicGenWorker.invalid_tags_error?(%{"detail" => [%{"msg" => "other error"}]})
    refute MusicGenWorker.invalid_tags_error?(%{})
  end
end
