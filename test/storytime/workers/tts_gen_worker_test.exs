defmodule Storytime.Workers.TtsGenWorkerTest do
  use ExUnit.Case, async: true

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
end
