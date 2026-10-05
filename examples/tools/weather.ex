defmodule MyApp.Tools.Weather do
  @moduledoc """
  An example tool that fetches current weather from the Open-Meteo API (no API key).

  Copy it into your application and rename the module. Normandy's live test
  `test/normandy_integration/basic_agent_test.exs` uses it: a model cannot know
  current weather, so it must call the tool.

      agent = Normandy.Agents.BaseAgent.register_tool(agent, %MyApp.Tools.Weather{})

  Supported cities are the keys of `@city_coords`.
  """

  defmodule Input do
    @moduledoc false
    use Normandy.Schema

    io_schema "Fetches current weather information for a given city using real-time data" do
      field(:city, :string,
        required: true,
        description: "The city name to get weather for (e.g., 'San Francisco', 'London', 'Tokyo')"
      )
    end
  end

  use Normandy.Tool,
    name: "weather",
    description: "Fetches current weather information for a given city using real-time data",
    input: Input

  alias Normandy.Tools.Context

  defstruct []

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
  Fetches the current weather of the input's city from the Open-Meteo API.
  """
  @impl Normandy.Tool
  def run(_tool, %Context{input: %Input{city: city}}) do
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

    # Req verifies TLS certificates by default and decodes the JSON body.
    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_weather_response(body, city)

      {:ok, %Req.Response{status: status}} ->
        {:error, "Failed to fetch weather: HTTP #{status}"}

      {:error, exception} ->
        {:error, "Failed to fetch weather: #{Exception.message(exception)}"}
    end
  end

  defp parse_weather_response(%{"current" => current}, city) do
    temp = Map.get(current, "temperature_2m")
    conditions = current |> Map.get("weather_code") |> weather_code_to_description()

    {:ok, "Current weather in #{city}: #{temp}°C, #{conditions}"}
  end

  defp parse_weather_response(_body, _city), do: {:error, "Failed to parse weather data"}

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
