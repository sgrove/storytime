defmodule Storytime.Notifier do
  @moduledoc false

  require Logger

  @spec broadcast(String.t(), String.t(), map()) :: :ok
  def broadcast(topic, event, payload) do
    StorytimeWeb.Endpoint.broadcast(topic, event, payload)
    :ok
  rescue
    exception ->
      Logger.warning(
        "Notifier broadcast failed topic=#{inspect(topic)} event=#{inspect(event)} reason=#{Exception.message(exception)}"
      )

      :ok
  end
end
