defmodule Storytime.Workers.DialogueGenWorkerLiveTest do
  use ExUnit.Case, async: false

  alias Storytime.Workers.DialogueGenWorker

  @moduletag :external
  @tag timeout: 120_000
  test "calls elevenlabs text-to-dialogue with timestamps successfully" do
    api_key = elevenlabs_api_key()

    if blank?(api_key) do
      {:skip, "ELEVENLABS_API_KEY not configured"}
    else
      inputs = [
        %{
          text: "Hello there, my name is Alice and I am happy to meet you.",
          voice_id: "Xb7hH8MSUJpSbSDYk0k2"
        },
        %{
          text: "Let's read this story together.",
          voice_id: "Xb7hH8MSUJpSbSDYk0k2"
        }
      ]

      assert {:ok, payload} = DialogueGenWorker.request_dialogue_timestamps_live(api_key, inputs)
      assert is_map(payload)
      assert is_list(payload["voice_segments"])

      alignment = payload["normalized_alignment"] || payload["alignment"] || %{}
      assert is_list(alignment["characters"])
      assert is_list(alignment["character_start_times_seconds"])
      assert is_list(alignment["character_end_times_seconds"])
      assert length(alignment["characters"]) > 0
    end
  end

  defp elevenlabs_api_key do
    System.get_env("ELEVENLABS_API_KEY") || key_from_api_keys_file()
  end

  defp key_from_api_keys_file do
    path = Path.expand("API_KEYS", File.cwd!())

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["ELEVENLABS_API_KEY", value] ->
            value |> String.trim() |> String.trim("\"")

          _ ->
            nil
        end
      end)
    else
      nil
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
