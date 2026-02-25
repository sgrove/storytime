defmodule Storytime.Stories.Page do
  @moduledoc false

  defstruct [
    :id,
    :story_id,
    :page_index,
    :scene_description,
    :narration_text,
    :scene_image_url,
    :narration_audio_url,
    :narration_timings_url,
    :sort_order
  ]
end
