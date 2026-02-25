defmodule Storytime.NotifierTest do
  use ExUnit.Case, async: true

  alias Storytime.Notifier

  test "broadcast returns ok for valid topic/event payloads" do
    assert :ok == Notifier.broadcast("story:test", "generation_progress", %{progress: 10})
  end

  test "broadcast swallows endpoint errors and returns ok" do
    assert :ok == Notifier.broadcast(nil, "generation_progress", %{progress: 10})
  end
end
