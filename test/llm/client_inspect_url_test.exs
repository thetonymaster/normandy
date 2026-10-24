defmodule Normandy.LLM.ClientInspectUrlTest do
  use ExUnit.Case, async: true

  alias Normandy.LLM.ClientInspect

  describe "sanitize_url/1" do
    test "keeps scheme, host, a non-default port and the path" do
      assert ClientInspect.sanitize_url("https://api.example.com/v1") ==
               "https://api.example.com/v1"

      assert ClientInspect.sanitize_url("http://localhost:4000/x") == "http://localhost:4000/x"
    end

    test "drops userinfo, query, fragment and a default port" do
      assert ClientInspect.sanitize_url("https://user:tok@api.example.com:443/v1?key=s#frag") ==
               "https://api.example.com/v1"
    end

    test "a URL with no scheme or host is nil" do
      assert ClientInspect.sanitize_url("api.example.com/v1?key=secret") == nil
      assert ClientInspect.sanitize_url("") == nil
    end
  end
end
