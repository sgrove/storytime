defmodule Storytime.Readiness do
  @moduledoc """
  Computes ship-readiness gaps for a story graph.

  The output is intentionally UI-friendly: each blocking item can optionally
  include a concrete channel event + payload for one-click remediation.
  """

  @type story_graph :: map()

  @spec evaluate(story_graph()) :: map()
  def evaluate(story) when is_map(story) do
    characters = story |> Map.get(:characters, []) |> sort_characters()
    pages = story |> Map.get(:pages, []) |> sort_pages()
    tracks = story |> Map.get(:music_tracks, []) |> sort_tracks()
    character_by_id = Map.new(characters, &{&1.id, &1})
    voiced_character_count = Enum.count(characters, &(not blank?(&1.voice_id)))

    items =
      []
      |> maybe_add_story_item_missing_characters(characters)
      |> maybe_add_story_item_missing_pages(pages)
      |> add_character_items(characters)
      |> add_page_items(pages, character_by_id, voiced_character_count)
      |> add_music_items(tracks)
      |> Enum.sort_by(&item_sort_key/1)

    blocking_items = Enum.filter(items, & &1.blocking)
    auto_fixable_items = Enum.filter(blocking_items, & &1.auto_fixable)
    warning_items = Enum.reject(items, & &1.blocking)

    %{
      ready: blocking_items == [],
      blocking_count: length(blocking_items),
      auto_fixable_count: length(auto_fixable_items),
      manual_count: length(blocking_items) - length(auto_fixable_items),
      warning_count: length(warning_items),
      items: Enum.map(items, &strip_private_fields/1)
    }
  end

  def evaluate(_), do: evaluate(%{})

  defp maybe_add_story_item_missing_characters(items, []),
    do:
      items ++
        [
          manual_item(
            "story:missing_characters",
            "missing_characters",
            "story",
            nil,
            nil,
            "Add at least one character.",
            "Dialogue and voice generation require characters with voices."
          )
        ]

  defp maybe_add_story_item_missing_characters(items, _characters), do: items

  defp maybe_add_story_item_missing_pages(items, []),
    do:
      items ++
        [
          manual_item(
            "story:missing_pages",
            "missing_pages",
            "story",
            nil,
            nil,
            "Add at least one page.",
            "Scene, narration, and dialogue generation require pages."
          )
        ]

  defp maybe_add_story_item_missing_pages(items, _pages), do: items

  defp add_character_items(items, characters) do
    Enum.reduce(characters, items, fn character, acc ->
      character_name = character.name || "Character"
      target_label = "Character \"#{character_name}\""

      acc
      |> maybe_add_character_name(character, target_label)
      |> maybe_add_character_voice(character, target_label)
      |> maybe_add_character_headshot(character, target_label)
    end)
  end

  defp maybe_add_character_name(items, character, target_label) do
    if text_blank?(character.name) do
      items ++
        [
          manual_item(
            "character:#{character.id}:name",
            "missing_character_name",
            "character",
            character.id,
            target_label,
            "Character is missing a name.",
            "Set a clear character name so dialogue and casting stay readable."
          )
        ]
    else
      items
    end
  end

  defp maybe_add_character_voice(items, character, target_label) do
    if blank?(character.voice_id) do
      items ++
        [
          manual_item(
            "character:#{character.id}:voice",
            "missing_character_voice",
            "character",
            character.id,
            target_label,
            "#{target_label} is missing a voice.",
            "Select an ElevenLabs voice so dialogue lines can generate audio."
          )
        ]
    else
      items
    end
  end

  defp maybe_add_character_headshot(items, character, target_label) do
    if blank?(character.headshot_url) do
      items ++
        [
          auto_item(
            "character:#{character.id}:headshot",
            "missing_headshot",
            "character",
            character.id,
            target_label,
            "#{target_label} is missing a headshot.",
            "Generate a headshot so cast and scene consistency work in reader mode.",
            "Generate Headshot",
            "generate_headshot",
            "headshot",
            %{"character_id" => character.id},
            %{character_name: character.name}
          )
        ]
    else
      items
    end
  end

  defp add_page_items(items, pages, character_by_id, voiced_character_count) do
    Enum.reduce(pages, items, fn page, acc ->
      page_number = page_number(page)
      target_label = "Page #{page_number}"

      acc
      |> maybe_add_scene_description(page, target_label, page_number)
      |> maybe_add_scene_image(page, target_label, page_number)
      |> maybe_add_narration_text(page, target_label, page_number)
      |> maybe_add_narration_assets(page, target_label, page_number)
      |> maybe_add_page_dialogue(page, target_label, page_number, voiced_character_count)
      |> add_dialogue_line_items(page, character_by_id, page_number)
    end)
  end

  defp maybe_add_scene_description(items, page, target_label, page_number) do
    if text_blank?(page.scene_description) do
      items ++
        [
          manual_item(
            "page:#{page.id}:scene_description",
            "missing_scene_description",
            "page",
            page.id,
            target_label,
            "#{target_label} is missing a scene description.",
            "Add scene text so image generation has clear composition guidance.",
            %{page_number: page_number}
          )
        ]
    else
      items
    end
  end

  defp maybe_add_scene_image(items, page, target_label, page_number) do
    if blank?(page.scene_image_url) do
      items ++
        [
          auto_item(
            "page:#{page.id}:scene_image",
            "missing_scene_image",
            "page",
            page.id,
            target_label,
            "#{target_label} is missing a scene image.",
            "Generate the page scene image for reader rendering.",
            "Generate Scene",
            "generate_scene",
            "scene",
            %{"page_id" => page.id},
            %{page_number: page_number}
          )
        ]
    else
      items
    end
  end

  defp maybe_add_narration_text(items, page, target_label, page_number) do
    if text_blank?(page.narration_text) do
      items ++
        [
          manual_item(
            "page:#{page.id}:narration_text",
            "missing_narration_text",
            "page",
            page.id,
            target_label,
            "#{target_label} is missing narration text.",
            "Add narration text before generating narration audio/timings.",
            %{page_number: page_number}
          )
        ]
    else
      items
    end
  end

  defp maybe_add_narration_assets(items, page, target_label, page_number) do
    missing_narration_audio = blank?(page.narration_audio_url)
    missing_narration_timings = blank?(page.narration_timings_url)

    cond do
      not missing_narration_audio and not missing_narration_timings ->
        items

      text_blank?(page.narration_text) ->
        items ++
          [
            manual_item(
              "page:#{page.id}:narration_assets_blocked",
              "missing_narration_assets",
              "page",
              page.id,
              target_label,
              "#{target_label} is missing narration audio/timings.",
              "Narration text is empty, so narration generation is currently blocked.",
              %{page_number: page_number}
            )
          ]

      true ->
        items ++
          [
            auto_item(
              "page:#{page.id}:narration_assets",
              "missing_narration_assets",
              "page",
              page.id,
              target_label,
              "#{target_label} is missing narration audio/timings.",
              "Generate narration to produce both narration audio and word timings.",
              "Generate Narration",
              "generate_narration_audio",
              "narration_tts",
              %{"page_id" => page.id},
              %{page_number: page_number}
            )
          ]
    end
  end

  defp maybe_add_page_dialogue(items, page, target_label, page_number, voiced_character_count) do
    lines = Map.get(page, :dialogue_lines, [])

    cond do
      lines != [] ->
        items

      voiced_character_count <= 0 ->
        items ++
          [
            manual_item(
              "page:#{page.id}:dialogue_blocked_no_voice",
              "missing_dialogue",
              "page",
              page.id,
              target_label,
              "#{target_label} has no dialogue lines.",
              "Add at least one character voice before auto-generating page dialogue.",
              %{page_number: page_number}
            )
          ]

      true ->
        line_count = voiced_character_count |> max(2) |> min(6)

        items ++
          [
            auto_item(
              "page:#{page.id}:dialogue",
              "missing_dialogue",
              "page",
              page.id,
              target_label,
              "#{target_label} has no dialogue lines.",
              "Generate dialogue lines and queue voice generation for each line.",
              "Generate Dialogue + Voices",
              "generate_dialogue",
              "dialogue",
              %{"page_id" => page.id, "line_count" => line_count},
              %{page_number: page_number}
            )
          ]
    end
  end

  defp add_dialogue_line_items(items, page, character_by_id, page_number) do
    lines = Map.get(page, :dialogue_lines, [])
    target_label = "Page #{page_number}"

    Enum.reduce(lines, items, fn line, acc ->
      line_index = (line.sort_order || 0) + 1
      line_label = "#{target_label} dialogue ##{line_index}"
      character = Map.get(character_by_id, line.character_id)
      missing_audio = blank?(line.audio_url)
      missing_timings = blank?(line.timings_url)

      cond do
        blank?(line.character_id) or is_nil(character) ->
          acc ++
            [
              manual_item(
                "dialogue:#{line.id}:character",
                "missing_dialogue_character",
                "dialogue",
                line.id,
                line_label,
                "#{line_label} is missing a valid speaker.",
                "Select a valid character for this dialogue line.",
                %{page_number: page_number, text_preview: line.text}
              )
            ]

        text_blank?(line.text) ->
          acc ++
            [
              manual_item(
                "dialogue:#{line.id}:text",
                "missing_dialogue_text",
                "dialogue",
                line.id,
                line_label,
                "#{line_label} is missing dialogue text.",
                "Write dialogue text before generating audio.",
                %{page_number: page_number}
              )
            ]

        not missing_audio and not missing_timings ->
          acc

        blank?(character.voice_id) ->
          acc ++
            [
              manual_item(
                "dialogue:#{line.id}:audio_blocked_voice",
                "missing_dialogue_audio",
                "dialogue",
                line.id,
                line_label,
                "#{line_label} is missing dialogue audio/timings.",
                "Speaker voice is missing. Assign a character voice, then regenerate line audio.",
                %{page_number: page_number, character_name: character.name}
              )
            ]

        true ->
          acc ++
            [
              auto_item(
                "dialogue:#{line.id}:audio",
                "missing_dialogue_audio",
                "dialogue",
                line.id,
                line_label,
                "#{line_label} is missing dialogue audio/timings.",
                "Generate dialogue audio with per-word timings.",
                "Generate Voice",
                "generate_dialogue_audio",
                "dialogue_tts",
                %{"dialogue_line_id" => line.id},
                %{
                  page_number: page_number,
                  character_name: character.name,
                  text_preview: line.text
                }
              )
            ]
      end
    end)
  end

  defp add_music_items(items, tracks) do
    Enum.reduce(tracks, items, fn track, acc ->
      target_label = "Music track \"#{track.title || track.id}\""
      base = "music:#{track.id}"

      if blank?(track.audio_url) do
        acc ++
          [
            auto_item(
              "#{base}:audio",
              "missing_music_audio",
              "music",
              track.id,
              target_label,
              "#{target_label} is missing generated audio.",
              "Generate the music track audio for reader playback.",
              "Generate Music",
              "generate_music",
              "music",
              %{"track_id" => track.id},
              %{text_preview: track.mood}
            )
          ]
      else
        acc
      end
    end)
  end

  defp manual_item(id, code, scope, target_id, target_label, message, detail, extra \\ %{}) do
    %{
      id: id,
      code: code,
      scope: scope,
      target_id: target_id,
      target_label: target_label,
      message: message,
      detail: detail,
      blocking: true,
      auto_fixable: false,
      action: nil
    }
    |> Map.merge(extra)
  end

  defp auto_item(
         id,
         code,
         scope,
         target_id,
         target_label,
         message,
         detail,
         action_label,
         event,
         job_type,
         payload,
         extra
       ) do
    %{
      id: id,
      code: code,
      scope: scope,
      target_id: target_id,
      target_label: target_label,
      message: message,
      detail: detail,
      blocking: true,
      auto_fixable: true,
      action: %{
        label: action_label,
        event: event,
        payload: payload,
        job_type: job_type,
        target_id: target_id,
        target_label: target_label
      }
    }
    |> Map.merge(extra)
  end

  defp strip_private_fields(item), do: item

  defp item_sort_key(item) do
    scope_order =
      case item.scope do
        "story" -> 0
        "character" -> 1
        "page" -> 2
        "dialogue" -> 3
        "music" -> 4
        _ -> 9
      end

    {
      if(item.blocking, do: 0, else: 1),
      scope_order,
      Map.get(item, :page_number, 0),
      item.message
    }
  end

  defp sort_characters(characters) do
    Enum.sort_by(characters, fn c ->
      {
        Map.get(c, :sort_order) || 0,
        Map.get(c, :inserted_at) || ~U[1970-01-01 00:00:00Z]
      }
    end)
  end

  defp sort_pages(pages) do
    Enum.sort_by(pages, fn p ->
      {
        Map.get(p, :page_index) || 0,
        Map.get(p, :sort_order) || 0
      }
    end)
  end

  defp sort_tracks(tracks) do
    Enum.sort_by(tracks, fn t ->
      {
        Map.get(t, :inserted_at) || ~U[1970-01-01 00:00:00Z],
        Map.get(t, :id) || ""
      }
    end)
  end

  defp page_number(page), do: (Map.get(page, :page_index) || 0) + 1

  defp blank?(value), do: value in [nil, ""]
  defp text_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp text_blank?(value), do: blank?(value)
end
