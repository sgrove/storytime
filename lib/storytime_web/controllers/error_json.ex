defmodule StorytimeWeb.ErrorJSON do
  def render(_template, _assigns), do: %{error: "not_found"}
end
