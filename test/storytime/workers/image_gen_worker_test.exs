defmodule Storytime.Workers.ImageGenWorkerTest do
  use ExUnit.Case, async: true

  alias Storytime.Workers.ImageGenWorker

  test "uses supported image defaults and the gpt-image-1.5 model" do
    assert ImageGenWorker.image_size_for("headshot") == "1024x1024"
    assert ImageGenWorker.image_size_for("scene") == "1536x1024"
    assert ImageGenWorker.openai_image_model() == "gpt-image-1.5"
    assert ImageGenWorker.openai_image_timeout_ms() >= 180_000
    assert ImageGenWorker.openai_connect_timeout_ms() >= 5_000
    assert ImageGenWorker.openai_pool_timeout_ms() >= 5_000
  end

  test "parses image timeout values with sane fallback" do
    assert ImageGenWorker.timeout_from_env("180000", 120_000, 30_000) == 180_000
    assert ImageGenWorker.timeout_from_env("   240000   ", 120_000, 30_000) == 240_000
    assert ImageGenWorker.timeout_from_env("not-a-number", 120_000, 30_000) == 120_000
    assert ImageGenWorker.timeout_from_env("12000", 120_000, 30_000) == 120_000
    assert ImageGenWorker.timeout_from_env(nil, 120_000, 30_000) == 120_000
  end

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

  test "force payload bypasses existing asset reuse" do
    story = %{
      characters: [%{id: "char-1", headshot_url: "https://assets.example/headshot_char-1.png"}],
      pages: []
    }

    assert {:ok, "https://assets.example/headshot_char-1.png"} =
             ImageGenWorker.reusable_asset_url(story, "headshot", "char-1", %{
               "payload" => %{"force" => false}
             })

    assert :none =
             ImageGenWorker.reusable_asset_url(story, "headshot", "char-1", %{
               "payload" => %{"force" => true}
             })
  end

  test "force payload parser accepts boolean and string truthy values" do
    assert ImageGenWorker.force_payload?(%{"payload" => %{"force" => true}})
    assert ImageGenWorker.force_payload?(%{"payload" => %{"force" => "true"}})
    assert ImageGenWorker.force_payload?(%{"payload" => %{"force" => 1}})
    refute ImageGenWorker.force_payload?(%{"payload" => %{"force" => false}})
    refute ImageGenWorker.force_payload?(%{"payload" => %{}})
  end
end
