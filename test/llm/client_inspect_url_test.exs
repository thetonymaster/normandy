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

    test "an IPv6 host keeps its bracketless host text and port, and no secret" do
      out = ClientInspect.sanitize_url("http://[::1]:8080/p?key=s")
      assert out =~ "::1"
      assert out =~ ":8080/p"
      refute out =~ "key"
    end

    test "a scheme-less URL with userinfo is nil, never its text" do
      assert ClientInspect.sanitize_url("user:tok@host/x") == nil
      assert ClientInspect.sanitize_url("host:80/x") == nil
    end

    test "a token in the path is kept (documented: only userinfo, query and fragment go)" do
      assert ClientInspect.sanitize_url("https://api.telegram.example/bot123:tok/send") ==
               "https://api.telegram.example/bot123:tok/send"
    end

    test "a URL with no scheme or host is nil" do
      assert ClientInspect.sanitize_url("api.example.com/v1?key=secret") == nil
      assert ClientInspect.sanitize_url("") == nil
    end
  end

  test "inspecting a client shows a non-binary base_url as is and a bad string as redacted" do
    assert inspect(%Normandy.LLM.OpenAICompatibleAdapter{base_url: nil}) =~ "base_url: nil"

    assert inspect(%Normandy.LLM.OpenAICompatibleAdapter{base_url: "user:tok@host/x"}) =~
             "**redacted**"
  end
end
