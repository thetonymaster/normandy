defmodule AutoresumeDemo.Web.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, AutoresumeDemo.Web.Page.html())
  end

  get "/events" do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    stream_loop(conn)
  end

  post "/kill/:node" do
    status =
      case safe_launcher(fn -> AutoresumeDemo.ClusterLauncher.kill(String.to_atom(node)) end) do
        :ok -> 202
        _ -> 404
      end

    send_resp(conn, status, "")
  end

  post "/restart/:slot" do
    status =
      case safe_launcher(fn -> AutoresumeDemo.ClusterLauncher.restart(String.to_atom(slot)) end) do
        :ok -> 202
        _ -> 404
      end

    send_resp(conn, status, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # The ClusterLauncher runs only in the :observer role (it spawns :peer nodes and
  # needs a distributed VM). When it isn't running (e.g. the router unit test), don't
  # let a GenServer.call to a missing process 500 the request — report 404 instead.
  defp safe_launcher(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :launcher_unavailable}
  end

  defp stream_loop(conn) do
    payload = AutoresumeDemo.DemoCollector.snapshot() |> Jason.encode!()

    case chunk(conn, "data: " <> payload <> "\n\n") do
      {:ok, conn} ->
        Process.sleep(500)
        stream_loop(conn)

      {:error, _} ->
        conn
    end
  end
end
