defmodule Storytime.Workers.TtsGenWorkerTest do
  use ExUnit.Case, async: false

  alias Storytime.Workers.TtsGenWorker

  test "dialogue_voice_ids handles unloaded character association safely" do
    unloaded = %Ecto.Association.NotLoaded{
      __field__: :character,
      __owner__: __MODULE__,
      __cardinality__: :one
    }

    assert {nil, nil} = TtsGenWorker.dialogue_voice_ids(%{character: unloaded})
  end

  test "dialogue_voice_ids returns configured character voice fields" do
    character = %{voice_id: "voice-123", voice_model_id: "eleven_multilingual_v2"}

    assert {"voice-123", "eleven_multilingual_v2"} =
             TtsGenWorker.dialogue_voice_ids(%{character: character})
  end

  test "non_retryable_reason identifies validation/config issues" do
    assert TtsGenWorker.non_retryable_reason?(:empty_text)
    assert TtsGenWorker.non_retryable_reason?(:missing_character_voice_id)
    assert TtsGenWorker.non_retryable_reason?(:missing_elevenlabs_api_key)
    assert TtsGenWorker.non_retryable_reason?({:missing_arg, "story_id"})
    refute TtsGenWorker.non_retryable_reason?({:elevenlabs_error, 500, %{}})
  end

  test "force payload bypasses cached dialogue audio reuse" do
    line = %{
      audio_url: "https://assets.example/dialogue.mp3",
      timings_url: "/assets/dialogue.json"
    }

    assert {:ok, "https://assets.example/dialogue.mp3", "/assets/dialogue.json"} =
             TtsGenWorker.reusable_audio_urls("dialogue", line, %{
               "payload" => %{"force" => false}
             })

    assert :none =
             TtsGenWorker.reusable_audio_urls("dialogue", line, %{
               "payload" => %{"force" => true}
             })
  end

  test "force payload parser accepts boolean/string/integer truthy values" do
    assert TtsGenWorker.force_payload?(%{"payload" => %{"force" => true}})
    assert TtsGenWorker.force_payload?(%{"payload" => %{"force" => "true"}})
    assert TtsGenWorker.force_payload?(%{"payload" => %{"force" => 1}})
    refute TtsGenWorker.force_payload?(%{"payload" => %{"force" => false}})
    refute TtsGenWorker.force_payload?(%{"payload" => %{}})
  end

  test "preserve timings payload parser accepts boolean/string/integer truthy values" do
    assert TtsGenWorker.preserve_timings_payload?(%{"payload" => %{"preserve_timings" => true}})
    assert TtsGenWorker.preserve_timings_payload?(%{"payload" => %{"preserve_timings" => "true"}})
    assert TtsGenWorker.preserve_timings_payload?(%{"payload" => %{"preserve_timings" => 1}})
    refute TtsGenWorker.preserve_timings_payload?(%{"payload" => %{"preserve_timings" => false}})
    refute TtsGenWorker.preserve_timings_payload?(%{"payload" => %{}})
  end

  test "reuses dialogue timings when preserve_timings is requested and timings_url exists" do
    line = %{timings_url: "/assets/story/dialogue_line_timings.json"}

    assert TtsGenWorker.should_reuse_timings?("dialogue", line, %{
             "payload" => %{"preserve_timings" => true}
           })

    refute TtsGenWorker.should_reuse_timings?("dialogue", %{timings_url: ""}, %{
             "payload" => %{"preserve_timings" => true}
           })

    refute TtsGenWorker.should_reuse_timings?("dialogue", line, %{
             "payload" => %{"preserve_timings" => false}
           })
  end

  test "default narrator voice id is used unless env override is present" do
    previous = System.get_env("ELEVENLABS_DEFAULT_VOICE_ID")

    on_exit(fn ->
      if previous == nil do
        System.delete_env("ELEVENLABS_DEFAULT_VOICE_ID")
      else
        System.put_env("ELEVENLABS_DEFAULT_VOICE_ID", previous)
      end
    end)

    System.delete_env("ELEVENLABS_DEFAULT_VOICE_ID")
    assert TtsGenWorker.default_voice_id() == "Xb7hH8MSUJpSbSDYk0k2"
    assert TtsGenWorker.resolve_voice_id(nil) == "Xb7hH8MSUJpSbSDYk0k2"

    System.put_env("ELEVENLABS_DEFAULT_VOICE_ID", "env-voice-123")
    assert TtsGenWorker.default_voice_id() == "env-voice-123"
    assert TtsGenWorker.resolve_voice_id("") == "env-voice-123"
    assert TtsGenWorker.resolve_voice_id("line-voice-999") == "line-voice-999"
  end
end
