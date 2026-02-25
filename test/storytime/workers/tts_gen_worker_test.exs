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
end
