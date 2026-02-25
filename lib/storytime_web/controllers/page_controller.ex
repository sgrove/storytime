defmodule StorytimeWeb.PageController do
  use StorytimeWeb, :controller

  def index(conn, _params) do
    html = """
    <!doctype html>
    <html>
      <head>
        <meta charset=\"utf-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
        <title>Storytime API</title>
        <style>
          body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 2rem; }
          .card { max-width: 760px; border: 1px solid #ddd; border-radius: 12px; padding: 1rem 1.25rem; }
          code { background: #f5f5f5; padding: 0.15rem 0.35rem; border-radius: 6px; }
        </style>
      </head>
      <body>
        <div class=\"card\">
          <h1>Storytime API is live</h1>
          <p>Phoenix skeleton is running on Render.</p>
          <p>Try <code>/health</code>, <code>/api/version</code>, and <code>/api/stories/demo/pack</code>.</p>
        </div>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end
end
