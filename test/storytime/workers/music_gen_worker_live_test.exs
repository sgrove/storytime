defmodule Storytime.Workers.MusicGenWorkerLiveTest do
  use ExUnit.Case, async: false

  alias Storytime.Workers.MusicGenWorker

  @moduletag :external
  @tag timeout: 600_000
  test "generates real mp3 bytes via sonauto" do
    if blank?(System.get_env("SONAUTO_API_KEY")) do
      {:skip, "SONAUTO_API_KEY not configured"}
    else
      restore_env =
        capture_env([
          "SONAUTO_POLL_ATTEMPTS",
          "SONAUTO_POLL_SLEEP_MS",
          "SONAUTO_POLL_REQUEST_TIMEOUT_MS",
          "SONAUTO_POLL_STALE_MS",
          "SONAUTO_POLL_MAX_ELAPSED_MS"
        ])

      on_exit(fn ->
        restore_env.()
      end)

      System.put_env("SONAUTO_POLL_ATTEMPTS", "120")
      System.put_env("SONAUTO_POLL_SLEEP_MS", "2000")
      System.put_env("SONAUTO_POLL_REQUEST_TIMEOUT_MS", "15000")
      System.put_env("SONAUTO_POLL_STALE_MS", "180000")
      System.put_env("SONAUTO_POLL_MAX_ELAPSED_MS", "300000")

      prompt =
        "Short cinematic instrumental underscore for a children's coding challenge, calm but tense, no vocals."

      assert {:ok, audio_bytes} = MusicGenWorker.generate_song(prompt)
      assert byte_size(audio_bytes) > 1_000
      assert mp3_payload?(audio_bytes)
    end
  end

  defp capture_env(keys) do
    snapshot = Map.new(keys, fn key -> {key, System.get_env(key)} end)

    fn ->
      Enum.each(snapshot, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp mp3_payload?(<<"ID3", _::binary>>), do: true
  defp mp3_payload?(<<0xFF, marker, _::binary>>) when marker in [0xFB, 0xF3, 0xF2], do: true
  defp mp3_payload?(_), do: false
end
