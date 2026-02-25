defmodule StorytimeWeb do
  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json],
        layouts: []

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defp verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: StorytimeWeb.Endpoint,
        router: StorytimeWeb.Router,
        statics: []
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
