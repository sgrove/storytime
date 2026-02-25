defmodule Storytime.GenerationGuardrailsTest do
  use ExUnit.Case, async: true

  alias Storytime.Generation

  test "validate_job_count enforces configurable request cap" do
    assert :ok == Generation.validate_job_count([{:scene, "p1"}, {:scene, "p2"}], 2)

    assert {:error, :too_many_jobs_requested} ==
             Generation.validate_job_count([{:scene, "p1"}], 0)

    assert {:error, :too_many_jobs_requested} ==
             Generation.validate_job_count([{:scene, "a"}, {:scene, "b"}, {:scene, "c"}], 2)
  end

  test "validate_single_job enforces existing targets for image/dialogue/music requests" do
    story = sample_story()

    assert :ok == Generation.validate_single_job(story, :headshot, "char-1")
    assert :ok == Generation.validate_single_job(story, :scene, "page-1")
    assert :ok == Generation.validate_single_job(story, :dialogue, "page-1")
    assert :ok == Generation.validate_single_job(story, :music, "track-1")

    assert {:error, :invalid_target} ==
             Generation.validate_single_job(story, :headshot, "missing")

    assert {:error, :invalid_target} == Generation.validate_single_job(story, :scene, "missing")

    assert {:error, :invalid_target} ==
             Generation.validate_single_job(story, :dialogue, "missing")

    assert {:error, :invalid_target} == Generation.validate_single_job(story, :music, "missing")
  end

  test "validate_single_job enforces dialogue_tts text and character voice" do
    story = sample_story()

    assert :ok == Generation.validate_single_job(story, :dialogue_tts, "line-1")

    assert {:error, :empty_text} ==
             Generation.validate_single_job(story, :dialogue_tts, "line-empty")

    assert {:error, :missing_character_voice_id} ==
             Generation.validate_single_job(story, :dialogue_tts, "line-novoice")

    assert {:error, :invalid_target} ==
             Generation.validate_single_job(story, :dialogue_tts, "line-missing")
  end

  test "validate_single_job enforces narration_tts page text" do
    story = sample_story()

    assert :ok == Generation.validate_single_job(story, :narration_tts, "page-1")

    assert {:error, :empty_text} ==
             Generation.validate_single_job(story, :narration_tts, "page-empty")

    assert {:error, :invalid_target} ==
             Generation.validate_single_job(story, :narration_tts, "missing")
  end

  test "missing audio guards treat absent timings as missing assets" do
    assert Generation.missing_dialogue_audio?(%{
             audio_url: "https://assets.example/dialogue.mp3",
             timings_url: nil
           })

    assert Generation.missing_dialogue_audio?(%{
             audio_url: nil,
             timings_url: "https://assets.example/dialogue_timings.json"
           })

    refute Generation.missing_dialogue_audio?(%{
             audio_url: "https://assets.example/dialogue.mp3",
             timings_url: "https://assets.example/dialogue_timings.json"
           })

    assert Generation.missing_narration_audio?(%{
             narration_audio_url: "https://assets.example/narration.mp3",
             narration_timings_url: nil
           })

    assert Generation.missing_narration_audio?(%{
             narration_audio_url: nil,
             narration_timings_url: "https://assets.example/narration_timings.json"
           })

    refute Generation.missing_narration_audio?(%{
             narration_audio_url: "https://assets.example/narration.mp3",
             narration_timings_url: "https://assets.example/narration_timings.json"
           })
  end

  defp sample_story do
    %{
      characters: [
        %{id: "char-1", voice_id: "voice-1"},
        %{id: "char-2", voice_id: nil}
      ],
      pages: [
        %{
          id: "page-1",
          narration_text: "Narration text",
          dialogue_lines: [
            %{id: "line-1", character_id: "char-1", text: "Hello"},
            %{id: "line-empty", character_id: "char-1", text: "   "},
            %{id: "line-novoice", character_id: "char-2", text: "I have no voice id"}
          ]
        },
        %{
          id: "page-empty",
          narration_text: "   ",
          dialogue_lines: []
        }
      ],
      music_tracks: [%{id: "track-1"}]
    }
  end
end
