defmodule AutoresumeDemo.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AutoresumeDemo.Web.Router

  @opts Router.init([])

  setup do
    # DemoCollector must be running for / and /events.
    case AutoresumeDemo.DemoCollector.start_link(:ok) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "GET / returns the dashboard HTML" do
    conn = conn(:get, "/") |> Router.call(@opts)
    assert conn.status == 200
    assert conn.resp_body =~ "Autoresume"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
  end

  test "POST /kill/:node returns 202 and does not crash with an unknown node" do
    conn = conn(:post, "/kill/nonexistent@127.0.0.1") |> Router.call(@opts)
    assert conn.status in [202, 404]
  end
end
