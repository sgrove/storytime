defmodule Storytime.Stories.GenerationJob do
  @moduledoc false

  defstruct [
    :id,
    :story_id,
    :job_type,
    :target_id,
    :status,
    :error
  ]
end
