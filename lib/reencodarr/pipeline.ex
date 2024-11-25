defmodule Reencodarr.Pipeline do
  @moduledoc """
    Convenience methods for working with the pipelines that power Reencodarr.
  """

  def start_video_scanner(path) do
    Reencodarr.Pipeline.Scanner.Video.start_link(path: path)
  end
end
