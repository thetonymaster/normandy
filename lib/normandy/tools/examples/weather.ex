defmodule Normandy.Tools.Examples.Weather do
  @moduledoc """
  A weather tool that fetches current weather data from Open-Meteo API.

  This tool is designed for integration testing to verify actual tool usage,
  as models cannot know real-time weather data and must use the tool.

  ## Examples

      iex> {:ok, weather} = Weather.validate(%{city: "San Francisco"})
      iex> Normandy.Tools.BaseTool.run(weather)
      {:ok, "Temperature: 15.2°C, Conditions: Clear sky"}

  ## API

  Uses the free Open-Meteo API (https://open-meteo.com/) which requires no API key.
  """

  use Normandy.Tools.SchemaBaseTool

  tool_schema "weather",
              "Fetches current weather information for a given city using real-time data" do
    field(:city, :string,
      required: true,
      description: "The city name to get weather for (e.g., 'San Francisco', 'London', 'Tokyo')"
    )
  end

  # City coordinates mapping (major cities)
  @city_coords %{
    "san francisco" => {37.7749, -122.4194},
    "london" => {51.5074, -0.1278},
    "tokyo" => {35.6762, 139.6503},
    "new york" => {40.7128, -74.0060},
    "paris" => {48.8566, 2.3522},
    "berlin" => {52.5200, 13.4050},
    "sydney" => {-33.8688, 151.2093},
    "toronto" => {43.6532, -79.3832},
    "mumbai" => {19.0760, 72.8777},
    "singapore" => {1.3521, 103.8198}
  }

  @doc """
  Executes the weather tool by fetching current weather from Open-Meteo API.
  """
  def execute(%__MODULE__{city: city}) do
    city_lower = String.downcase(city)

    case Map.get(@city_coords, city_lower) do
      nil ->
        {:error, "City '#{city}' not found. Supported cities: #{supported_cities()}"}

      {lat, lon} ->
        fetch_weather(lat, lon, city)
    end
  end

  defp fetch_weather(lat, lon, city) do
    url =
      "https://api.open-meteo.com/v1/forecast?latitude=#{lat}&longitude=#{lon}&current=temperature_2m,weather_code&temperature_unit=celsius"

    case http_get(url) do
      {:ok, body} ->
        parse_weather_response(body, city)

      {:error, reason} ->
        {:error, "Failed to fetch weather: #{inspect(reason)}"}
    end
  end

  defp http_get(url) do
    url_charlist = String.to_charlist(url)

    # Start required applications if not already started
    _ = :inets.start()
    _ = :ssl.start()

    case :httpc.request(:get, {url_charlist, []}, [{:timeout, 10_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status_code, _}, _headers, _body}} ->
        {:error, "HTTP #{status_code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_weather_response(body, city) do
    case Poison.decode(body) do
      {:ok, %{"current" => current}} ->
        temp = Map.get(current, "temperature_2m")
        weather_code = Map.get(current, "weather_code")
        conditions = weather_code_to_description(weather_code)

        {:ok, "Current weather in #{city}: #{temp}°C, #{conditions}"}

      {:error, _} ->
        {:error, "Failed to parse weather data"}
    end
  end

  # WMO Weather interpretation codes
  # https://open-meteo.com/en/docs
  defp weather_code_to_description(0), do: "Clear sky"
  defp weather_code_to_description(1), do: "Mainly clear"
  defp weather_code_to_description(2), do: "Partly cloudy"
  defp weather_code_to_description(3), do: "Overcast"
  defp weather_code_to_description(code) when code in [45, 48], do: "Foggy"
  defp weather_code_to_description(code) when code in [51, 53, 55], do: "Drizzle"
  defp weather_code_to_description(code) when code in [61, 63, 65], do: "Rain"
  defp weather_code_to_description(code) when code in [71, 73, 75], do: "Snow"
  defp weather_code_to_description(code) when code in [80, 81, 82], do: "Rain showers"
  defp weather_code_to_description(code) when code in [95, 96, 99], do: "Thunderstorm"
  defp weather_code_to_description(_), do: "Unknown conditions"

  defp supported_cities do
    @city_coords
    |> Map.keys()
    |> Enum.sort()
    |> Enum.join(", ")
  end
end
