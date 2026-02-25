defmodule Storytime.Workers.ImageGenWorkerTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.ImageGenWorker

  test "falls back from legacy 512x512 headshot size on openai invalid size error" do
    body = %{
      "error" => %{
        "code" => "invalid_value",
        "param" => "size",
        "message" =>
          "Invalid value: '512x512'. Supported values are: '1024x1024', '1024x1536', '1536x1024', and 'auto'."
      }
    }

    assert ImageGenWorker.should_fallback_size?(400, body, "512x512")
    assert ImageGenWorker.fallback_size_for("512x512") == "1024x1024"
  end

  test "does not fallback for non-size errors or already-supported sizes" do
    assert ImageGenWorker.should_fallback_size?(500, %{}, "512x512") == false

    assert ImageGenWorker.should_fallback_size?(
             400,
             %{"error" => %{"code" => "invalid_value"}},
             "1536x1024"
           ) == false

    assert ImageGenWorker.fallback_size_for("1536x1024") == nil
  end
end
