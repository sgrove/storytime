defmodule Storytime.Stories.Character do
  @moduledoc false

  defstruct [
    :id,
    :story_id,
    :name,
    :visual_description,
    :voice_provider,
    :voice_id,
    :voice_model_id,
    :headshot_url,
    :sort_order
  ]
end
