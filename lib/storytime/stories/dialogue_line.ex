defmodule Storytime.Stories.DialogueLine do
  @moduledoc false

  defstruct [
    :id,
    :page_id,
    :character_id,
    :text,
    :audio_url,
    :timings_url,
    :sort_order
  ]
end
