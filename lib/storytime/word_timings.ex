defmodule Storytime.WordTimings do
  @moduledoc """
  WordTimings V2 helpers.
  """

  @spec from_alignment(String.t(), map() | nil, keyword()) :: map()
  def from_alignment(text, alignment, opts \\ []) when is_binary(text) do
    fallback_duration = Keyword.get(opts, :fallback_duration_ms, max(String.length(text) * 45, 500))

    case extract_arrays(alignment) do
      {:ok, starts_ms, ends_ms} -> from_arrays(text, starts_ms, ends_ms)
      :error -> fallback(text, fallback_duration)
    end
  end

  @spec fallback(String.t(), non_neg_integer()) :: map()
  def fallback(text, total_duration_ms) do
    words = word_ranges(text)

    {word_entries, max_end} =
      words
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {{word, char_start, char_end}, idx}, _acc ->
        count = max(length(words), 1)
        start_ms = round(idx * total_duration_ms / count)
        end_ms = round((idx + 1) * total_duration_ms / count)

        entry = %{
          "word" => word,
          "startMs" => start_ms,
          "endMs" => max(end_ms, start_ms + 1),
          "charStart" => char_start,
          "charEnd" => char_end
        }

        {entry, max(end_ms, start_ms + 1)}
      end)

    %{
      "schemaVersion" => 2,
      "segments" => [
        %{
          "id" => "seg-0",
          "startMs" => 0,
          "endMs" => max(max_end, 1),
          "text" => text,
          "words" => word_entries
        }
      ],
      "totalDurationMs" => max(max_end, 1)
    }
  end

  defp from_arrays(text, starts_ms, ends_ms) do
    words = word_ranges(text)

    entries =
      Enum.map(words, fn {word, char_start, char_end} ->
        start_ms = safe_at(starts_ms, char_start, 0)
        end_ms = safe_at(ends_ms, max(char_end - 1, 0), start_ms + 80)

        %{
          "word" => word,
          "startMs" => start_ms,
          "endMs" => max(end_ms, start_ms + 1),
          "charStart" => char_start,
          "charEnd" => char_end
        }
      end)

    total_duration =
      entries
      |> Enum.reduce(1, fn w, acc -> max(acc, Map.get(w, "endMs", 1)) end)

    %{
      "schemaVersion" => 2,
      "segments" => [
        %{
          "id" => "seg-0",
          "startMs" => 0,
          "endMs" => total_duration,
          "text" => text,
          "words" => entries
        }
      ],
      "totalDurationMs" => total_duration
    }
  end

  defp extract_arrays(nil), do: :error

  defp extract_arrays(alignment) when is_map(alignment) do
    starts =
      Map.get(alignment, "character_start_times_seconds") ||
        Map.get(alignment, "character_start_times") || []

    ends =
      Map.get(alignment, "character_end_times_seconds") ||
        Map.get(alignment, "character_end_times") || []

    cond do
      is_list(starts) and starts != [] ->
        starts_ms = Enum.map(starts, &seconds_to_ms/1)

        ends_ms =
          if is_list(ends) and length(ends) == length(starts) do
            Enum.map(ends, &seconds_to_ms/1)
          else
            infer_end_times(starts_ms)
          end

        {:ok, starts_ms, ends_ms}

      true ->
        :error
    end
  end

  defp extract_arrays(_), do: :error

  defp infer_end_times(starts_ms) do
    starts_ms
    |> Enum.with_index()
    |> Enum.map(fn {start_ms, idx} ->
      next = Enum.at(starts_ms, idx + 1)
      if is_integer(next), do: max(next - 1, start_ms + 1), else: start_ms + 80
    end)
  end

  defp seconds_to_ms(value) when is_integer(value), do: value * 1000
  defp seconds_to_ms(value) when is_float(value), do: round(value * 1000)

  defp seconds_to_ms(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> round(num * 1000)
      :error -> 0
    end
  end

  defp seconds_to_ms(_), do: 0

  defp word_ranges(text) do
    Regex.scan(~r/\S+/, text, return: :index)
    |> Enum.map(fn [{start, len}] ->
      {binary_part(text, start, len), start, start + len}
    end)
  end

  defp safe_at(list, idx, fallback) do
    case Enum.at(list, idx) do
      value when is_integer(value) -> value
      _ -> fallback
    end
  end
end
