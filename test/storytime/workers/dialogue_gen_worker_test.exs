defmodule Storytime.Workers.DialogueGenWorkerTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.DialogueGenWorker

  @characters [
    %{id: "char-1", name: "Luna"},
    %{id: "char-2", name: "Milo"}
  ]

  describe "extract_openai_content/1" do
    test "reads text from chat-completions string content" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => "{\"lines\":[]}"}}
        ]
      }

      assert {:ok, "{\"lines\":[]}"} = DialogueGenWorker.extract_openai_content(response)
    end

    test "reads text from typed content payload" do
      response = %{
        "choices" => [
          %{"message" => %{"content" => [%{"type" => "text", "text" => "{\"lines\":[]}"}]}}
        ]
      }

      assert {:ok, "{\"lines\":[]}"} = DialogueGenWorker.extract_openai_content(response)
    end

    test "rejects invalid payload shape" do
      assert {:error, :invalid_llm_response} = DialogueGenWorker.extract_openai_content(%{})
    end
  end

  describe "normalize_llm_lines/3" do
    test "accepts id-based lines and trims to requested count" do
      decoded = %{
        "lines" => [
          %{"character_id" => "char-1", "text" => "Hello there!"},
          %{"character_id" => "char-2", "text" => "Welcome to the garden."},
          %{"character_id" => "char-1", "text" => "Too many lines"}
        ]
      }

      assert {:ok, lines} = DialogueGenWorker.normalize_llm_lines(decoded, @characters, 2)
      assert length(lines) == 2
      assert Enum.at(lines, 0).character_id == "char-1"
      assert Enum.at(lines, 1).character_id == "char-2"
    end

    test "resolves characters by name when id missing" do
      decoded = %{
        "lines" => [
          %{"character_name" => "luna", "text" => "Let's begin."},
          %{"characterName" => "Milo", "text" => "I found a clue."}
        ]
      }

      assert {:ok, lines} = DialogueGenWorker.normalize_llm_lines(decoded, @characters, 2)
      assert Enum.at(lines, 0).character_id == "char-1"
      assert Enum.at(lines, 1).character_id == "char-2"
    end

    test "falls back to available characters when id invalid" do
      decoded = %{
        "lines" => [
          %{"character_id" => "unknown", "text" => "One"},
          %{"character_id" => "unknown", "text" => "Two"}
        ]
      }

      assert {:ok, lines} = DialogueGenWorker.normalize_llm_lines(decoded, @characters, 2)
      assert Enum.map(lines, & &1.character_id) == ["char-1", "char-2"]
    end

    test "errors when no usable lines are returned" do
      assert {:error, :invalid_dialogue_lines} =
               DialogueGenWorker.normalize_llm_lines(
                 %{"lines" => [%{"text" => ""}]},
                 @characters,
                 2
               )
    end
  end

  describe "normalize_dialogue_inputs/1" do
    test "accepts tuple and map entries and normalizes to voice_id/text maps" do
      inputs = [
        {"voice-1", " Hello "},
        %{"voice_id" => "voice-2", "text" => "World"},
        %{voice_id: "voice-3", text: "Again"}
      ]

      assert {:ok, normalized} = DialogueGenWorker.normalize_dialogue_inputs(inputs)

      assert normalized == [
               %{voice_id: "voice-1", text: "Hello"},
               %{voice_id: "voice-2", text: "World"},
               %{voice_id: "voice-3", text: "Again"}
             ]
    end

    test "rejects empty or invalid entries" do
      assert {:error, :empty_dialogue_inputs} = DialogueGenWorker.normalize_dialogue_inputs([])

      assert {:error, :invalid_dialogue_input_voice_id} =
               DialogueGenWorker.normalize_dialogue_inputs([{nil, "hi"}])

      assert {:error, :invalid_dialogue_input_text} =
               DialogueGenWorker.normalize_dialogue_inputs([{"voice-1", ""}])

      assert {:error, :invalid_dialogue_input} =
               DialogueGenWorker.normalize_dialogue_inputs([:bad])
    end
  end
end
