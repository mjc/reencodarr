defmodule ReencodarrWeb.VideoPresentation do
  @moduledoc false
  def season_directory(path) when is_binary(path) do
    dir = Path.dirname(path)

    if Regex.match?(~r/^[Ss](?:eason\s*)?0*\d+$/i, Path.basename(dir)) do
      dir
    else
      nil
    end
  end

  def season_directory(_path), do: nil
end
