defmodule Storytime.Router do
  use Plug.Router

  plug Plug.Logger
  plug :match
  plug :dispatch

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  get "/" do
    html = """
    <!doctype html>
    <html>
      <head>
        <meta charset=\"utf-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
        <title>Storytime Bootstrap</title>
        <style>
          body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 2rem; }
          .card { max-width: 720px; padding: 1rem 1.25rem; border: 1px solid #ddd; border-radius: 12px; }
          code { background: #f6f6f6; padding: 0.15rem 0.3rem; border-radius: 6px; }
        </style>
      </head>
      <body>
        <div class=\"card\">
          <h1>Storytime bootstrap is live</h1>
          <p>Minimal Elixir web shell is running on Render.</p>
          <p>Health check: <code>/health</code></p>
        </div>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
