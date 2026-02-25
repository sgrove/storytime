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

  test "scene references include page characters in dialogue order with absolute urls" do
    previous_host = System.get_env("PHX_HOST")
    System.put_env("PHX_HOST", "storytime-api-091733.onrender.com")

    on_exit(fn ->
      if previous_host == nil do
        System.delete_env("PHX_HOST")
      else
        System.put_env("PHX_HOST", previous_host)
      end
    end)

    story = %{
      characters: [
        %{
          id: "char-1",
          name: "Luna",
          visual_description: "fox",
          headshot_url: "/assets/story/char-1.png"
        },
        %{id: "char-2", name: "Oliver", visual_description: "owl", headshot_url: ""},
        %{
          id: "char-3",
          name: "Milo",
          visual_description: "cat",
          headshot_url: "/assets/story/char-3.png"
        }
      ],
      pages: [
        %{
          id: "page-1",
          dialogue_lines: [
            %{id: "line-2", character_id: "char-1", sort_order: 2},
            %{id: "line-1", character_id: "char-3", sort_order: 1},
            %{id: "line-3", character_id: "char-1", sort_order: 3},
            %{id: "line-4", character_id: "char-2", sort_order: 4}
          ]
        }
      ]
    }

    refs = ImageGenWorker.scene_character_references(story, "page-1")

    assert Enum.map(refs, & &1.character_id) == ["char-3", "char-1"]
    assert Enum.map(refs, & &1.name) == ["Milo", "Luna"]

    assert Enum.map(refs, & &1.image_url) == [
             "https://storytime-api-091733.onrender.com/assets/story/char-3.png",
             "https://storytime-api-091733.onrender.com/assets/story/char-1.png"
           ]
  end

  test "scene references include all valid characters (no hard cap)" do
    previous_host = System.get_env("PHX_HOST")
    System.put_env("PHX_HOST", "storytime-api-091733.onrender.com")

    on_exit(fn ->
      if previous_host == nil do
        System.delete_env("PHX_HOST")
      else
        System.put_env("PHX_HOST", previous_host)
      end
    end)

    characters =
      Enum.map(1..8, fn idx ->
        %{
          id: "char-#{idx}",
          name: "Character #{idx}",
          visual_description: "desc #{idx}",
          headshot_url: "/assets/story/char-#{idx}.png"
        }
      end)

    dialogue_lines =
      Enum.map(1..8, fn idx ->
        %{id: "line-#{idx}", character_id: "char-#{idx}", sort_order: idx}
      end)

    story = %{
      characters: characters,
      pages: [%{id: "page-1", dialogue_lines: dialogue_lines}]
    }

    refs = ImageGenWorker.scene_character_references(story, "page-1")

    assert length(refs) == 8
    assert Enum.map(refs, & &1.character_id) == Enum.map(1..8, &"char-#{&1}")
  end

  test "extracts generated image bytes from responses api payload" do
    image_bytes = "png-bytes"

    body = %{
      "output" => [
        %{
          "type" => "image_generation_call",
          "result" => Base.encode64(image_bytes)
        }
      ]
    }

    assert {:ok, ^image_bytes} = ImageGenWorker.extract_responses_image_bytes(body)
  end

  test "returns invalid_image_payload when responses payload has no image output" do
    assert {:error, :invalid_image_payload} =
             ImageGenWorker.extract_responses_image_bytes(%{"output" => []})
  end
end
