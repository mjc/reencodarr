defmodule Reencodarr.Statistics.State do
  defstruct stats: %Reencodarr.Statistics.Stats{},
            encoding: false,
            crf_searching: false,
            encoding_progress: %Reencodarr.Statistics.EncodingProgress{
              filename: :none,
              percent: 0,
              eta: 0,
              fps: 0
            },
            crf_search_progress: %Reencodarr.Statistics.CrfSearchProgress{
              filename: :none,
              percent: 0,
              eta: 0,
              fps: 0,
              crf: 0,
              score: 0
            },
            syncing: false,
            sync_progress: 0
end
