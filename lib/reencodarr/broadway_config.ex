defmodule Reencodarr.BroadwayConfig do
  @moduledoc """
  Centralized Broadway configuration utilities.

  Eliminates duplication across Broadway pipeline modules by providing
  a consistent config merging pattern: defaults → app config → runtime opts.
  """

  @doc """
  Merges configuration layers with proper precedence.

  Configuration priority (highest to lowest):
  1. Runtime options (passed to start_link)
  2. Application environment config
  3. Module default config

  ## Examples

      iex> defaults = [rate_limit_messages: 10, batch_size: 1]
      iex> opts = [batch_size: 5]
      iex> BroadwayConfig.merge_config(MyModule, defaults, opts)
      [rate_limit_messages: 10, batch_size: 5]

  """
  @spec merge_config(module(), keyword(), keyword()) :: keyword()
  def merge_config(module, default_config, opts \\ []) do
    app_config = Application.get_env(:reencodarr, module, [])

    default_config
    |> Keyword.merge(app_config)
    |> Keyword.merge(opts)
  end

  @doc """
  Creates standardized rate limiting configuration.

  ## Examples

      iex> config = [rate_limit_messages: 5, rate_limit_interval: 2000]
      iex> BroadwayConfig.rate_limiting_config(config)
      [allowed_messages: 5, interval: 2000]

  """
  @spec rate_limiting_config(keyword()) :: keyword()
  def rate_limiting_config(config) do
    [
      allowed_messages: config[:rate_limit_messages],
      interval: config[:rate_limit_interval]
    ]
  end

  @doc """
  Creates standardized processor configuration.

  ## Examples

      iex> BroadwayConfig.processor_config()
      [default: [concurrency: 1, max_demand: 1]]

  """
  @spec processor_config() :: keyword()
  def processor_config do
    [
      default: [
        concurrency: 1,
        max_demand: 1
      ]
    ]
  end

  @doc """
  Creates standardized batcher configuration for CRF search.

  ## Examples

      iex> config = [batch_size: 3, batch_timeout: 5000]
      iex> BroadwayConfig.crf_search_batcher_config(config)
      [default: [batch_size: 3, batch_timeout: 5000]]

  """
  @spec crf_search_batcher_config(keyword()) :: keyword()
  def crf_search_batcher_config(config) do
    [
      default: [
        batch_size: config[:batch_size],
        batch_timeout: config[:batch_timeout]
      ]
    ]
  end

  @doc """
  Creates standardized batcher configuration for encoding.

  ## Examples

      iex> config = [batch_size: 1, batch_timeout: 10000]  
      iex> BroadwayConfig.encoding_batcher_config(config)
      [default: [batch_size: 1, batch_timeout: 10000]]

  """
  @spec encoding_batcher_config(keyword()) :: keyword()
  def encoding_batcher_config(config) do
    [
      default: [
        batch_size: config[:batch_size],
        batch_timeout: config[:batch_timeout]
      ]
    ]
  end
end
