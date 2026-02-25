defmodule Storytime.Stories.Story do
  @moduledoc false

  defstruct [
    :id,
    :title,
    :slug,
    :art_style,
    :status,
    :deploy_url,
    :render_site_id
  ]
end
