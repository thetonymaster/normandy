defmodule NormandyTest.Components.ContextProviderTest do
  use ExUnit.Case, async: true

  alias Normandy.Components.ContextProvider

  defmodule DateTimeProvider do
    defstruct [:format]

    defimpl Normandy.Components.ContextProvider do
      def title(%{format: :short}), do: "Current Time"
      def title(%{format: :long}), do: "Current Date and Time"
      def title(_), do: "DateTime"

      def get_info(%{format: :short}) do
        DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()
      end

      def get_info(%{format: :long}) do
        DateTime.utc_now() |> DateTime.to_string()
      end

      def get_info(_) do
        DateTime.utc_now() |> DateTime.to_iso8601()
      end
    end
  end

  defmodule UserContextProvider do
    defstruct [:user_id, :user_name, :user_role]

    defimpl Normandy.Components.ContextProvider do
      def title(_), do: "User Information"

      def get_info(%{user_id: id, user_name: name, user_role: role}) do
        """
        User ID: #{id}
        Name: #{name}
        Role: #{role}
        """
      end
    end
  end

  defmodule SystemInfoProvider do
    defstruct []

    defimpl Normandy.Components.ContextProvider do
      def title(_), do: "System Information"

      def get_info(_) do
        """
        Elixir Version: #{System.version()}
        OTP Release: #{System.otp_release()}
        """
      end
    end
  end

  describe "ContextProvider protocol" do
    test "DateTimeProvider with short format" do
      provider = %DateTimeProvider{format: :short}
      assert ContextProvider.title(provider) == "Current Time"
      info = ContextProvider.get_info(provider)
      # Just verify it returns a string that looks like a time
      assert is_binary(info)
      assert String.contains?(info, ":")
    end

    test "DateTimeProvider with long format" do
      provider = %DateTimeProvider{format: :long}
      assert ContextProvider.title(provider) == "Current Date and Time"
      info = ContextProvider.get_info(provider)
      assert is_binary(info)
      # Should contain both date and time components
      assert String.contains?(info, "-")
      assert String.contains?(info, ":")
    end

    test "DateTimeProvider with default format" do
      provider = %DateTimeProvider{format: nil}
      assert ContextProvider.title(provider) == "DateTime"
      info = ContextProvider.get_info(provider)
      assert is_binary(info)
      # ISO8601 format
      assert String.contains?(info, "T")
      assert String.contains?(info, "Z")
    end

    test "UserContextProvider returns user information" do
      provider = %UserContextProvider{
        user_id: 123,
        user_name: "Alice Smith",
        user_role: "admin"
      }

      assert ContextProvider.title(provider) == "User Information"
      info = ContextProvider.get_info(provider)
      assert String.contains?(info, "User ID: 123")
      assert String.contains?(info, "Name: Alice Smith")
      assert String.contains?(info, "Role: admin")
    end

    test "SystemInfoProvider returns system information" do
      provider = %SystemInfoProvider{}
      assert ContextProvider.title(provider) == "System Information"
      info = ContextProvider.get_info(provider)
      assert String.contains?(info, "Elixir Version:")
      assert String.contains?(info, "OTP Release:")
    end
  end

  describe "Multiple context providers" do
    test "different providers can coexist" do
      date_provider = %DateTimeProvider{format: :short}
      user_provider = %UserContextProvider{
        user_id: 456,
        user_name: "Bob Jones",
        user_role: "user"
      }

      assert ContextProvider.title(date_provider) == "Current Time"
      assert ContextProvider.title(user_provider) == "User Information"

      date_info = ContextProvider.get_info(date_provider)
      user_info = ContextProvider.get_info(user_provider)

      assert is_binary(date_info)
      assert String.contains?(user_info, "Bob Jones")
    end
  end

  describe "Context provider with agent" do
    test "can register and retrieve context provider" do
      alias Normandy.Agents.BaseAgent

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)
      provider = %DateTimeProvider{format: :long}

      agent = BaseAgent.register_context_provider(agent, :datetime, provider)
      retrieved = BaseAgent.get_context_provider(agent, :datetime)

      assert retrieved == provider
      assert ContextProvider.title(retrieved) == "Current Date and Time"
    end

    test "can delete context provider" do
      alias Normandy.Agents.BaseAgent

      config = %{
        client: %NormandyTest.Support.ModelMockup{},
        model: "test-model",
        temperature: 0.7
      }

      agent = BaseAgent.init(config)
      provider = %UserContextProvider{user_id: 1, user_name: "Test", user_role: "test"}

      agent = BaseAgent.register_context_provider(agent, :user, provider)
      agent = BaseAgent.delete_context_provider(agent, :user)

      assert_raise Normandy.NonExistentContextProvider, fn ->
        BaseAgent.get_context_provider(agent, :user)
      end
    end
  end
end
