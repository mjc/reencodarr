defmodule Reencodarr.BroadwayConfig do
  @moduledoc "Shared Broadway startup configuration for single-worker pipelines."

  @spec start_link(module(), module(), keyword(), keyword()) :: GenServer.on_start()
  def start_link(pipeline, producer, default_config, opts) do
    app_config = Application.get_env(:reencodarr, pipeline, [])
    config = default_config |> Keyword.merge(app_config) |> Keyword.merge(opts)

    Broadway.start_link(pipeline,
      name: pipeline,
      producer: [
        module: {producer, []},
        transformer: {pipeline, :transform, []},
        rate_limiting: [
          allowed_messages: config[:rate_limit_messages],
          interval: config[:rate_limit_interval]
        ]
      ],
      processors: [
        default: [
          concurrency: 1,
          max_demand: 1
        ]
      ],
      batchers: [
        default: [
          batch_size: config[:batch_size],
          batch_timeout: config[:batch_timeout],
          concurrency: 1
        ]
      ],
      context: %{
        rate_limit_messages: config[:rate_limit_messages],
        rate_limit_interval: config[:rate_limit_interval]
      }
    )
  end
end
