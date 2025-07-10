defmodule Reencodarr.Encoder.Broadway do
  @moduledoc """
  Broadway pipeline for encoding operations.

  This module provides a Broadway pipeline that respects the single-worker
  limitation of the encoding GenServer, preventing duplicate work.

  The pipeline is configured with:
  - Single concurrency to prevent resource conflicts
  - Rate limiting to avoid overwhelming the system
  - Proper error handling and telemetry
  - Configurable batch processing
  """

  use Broadway
  require Logger

  alias Broadway.Message

  @typedoc "VMAF struct for encoding processing"
  @type vmaf :: %{id: integer(), video: map()}

  @typedoc "Broadway pipeline configuration"
  @type config :: keyword()

  # Configuration constants
  @default_config [
    rate_limit_messages: 5,
    rate_limit_interval: 1_000
  ]

  @doc """
  Start the Broadway pipeline with configurable options.

  ## Options
    * `:rate_limit_messages` - Number of messages allowed per interval (default: 5)
    * `:rate_limit_interval` - Rate limit interval in milliseconds (default: 1000)
    * `:batch_size` - Number of messages per batch (default: 1)
    * `:batch_timeout` - Batch timeout in milliseconds (default: 10000)

  ## Examples
      iex> Reencodarr.Encoder.Broadway.start_link([])
      {:ok, pid}

      iex> Reencodarr.Encoder.Broadway.start_link([rate_limit_messages: 3])
      {:ok, pid}
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(opts) do
    app_config = Application.get_env(:reencodarr, __MODULE__, [])
    config = @default_config |> Keyword.merge(app_config) |> Keyword.merge(opts)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Reencodarr.Encoder.Broadway.Producer, []},
        transformer: {__MODULE__, :transform, []},
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
      ]
    )
  end

  @doc """
  Add a VMAF to the pipeline for encoding processing.

  ## Parameters
    * `vmaf` - VMAF struct containing id and video data

  ## Examples
      iex> vmaf = %{id: 1, video: %{path: "/path/to/video.mp4"}}
      iex> Reencodarr.Encoder.Broadway.process_vmaf(vmaf)
      :ok
  """
  @spec process_vmaf(vmaf()) :: :ok | {:error, term()}
  def process_vmaf(vmaf) do
    case Reencodarr.Encoder.Broadway.Producer.add_vmaf(vmaf) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if the encoder pipeline is running (not paused).

  ## Examples
      iex> Reencodarr.Encoder.Broadway.running?()
      true
  """
  @spec running?() :: boolean()
  def running? do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         true <- Process.alive?(pid) do
      Reencodarr.Encoder.Broadway.Producer.running?()
    else
      _ -> false
    end
  end

  @doc """
  Pause the encoder pipeline.

  ## Examples
      iex> Reencodarr.Encoder.Broadway.pause()
      :ok
  """
  @spec pause() :: :ok | {:error, term()}
  def pause do
    Reencodarr.Encoder.Broadway.Producer.pause()
  end

  @doc """
  Resume the encoder pipeline.

  ## Examples
      iex> Reencodarr.Encoder.Broadway.resume()
      :ok
  """
  @spec resume() :: :ok | {:error, term()}
  def resume do
    Reencodarr.Encoder.Broadway.Producer.resume()
  end

  @doc """
  Start the encoder pipeline.

  Alias for `resume/0` to maintain API compatibility.
  """
  @spec start() :: :ok | {:error, term()}
  def start, do: resume()

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, _context) do
    # Start encoding asynchronously but wait for completion to maintain single-concurrency
    task =
      Task.async(fn ->
        process_vmaf_encoding(message.data)
      end)

    # Wait for the task to complete - process_vmaf_encoding handles all logging internally
    case Task.await(task, :infinity) do
      :ok ->
        # Success/failure logging is handled within process_vmaf_encoding
        message

      {:error, reason} ->
        # This should not happen since process_vmaf_encoding always returns :ok now
        Logger.warning(
          "Broadway: Unexpected error from process_vmaf_encoding for VMAF #{message.data.id}: #{reason}"
        )

        message
    end
  end

  @doc """
  Transform raw VMAF data into a Broadway message.

  This function is called by the Broadway producer to transform
  events into messages that can be processed by the pipeline.
  """
  @spec transform(vmaf(), keyword()) :: Message.t()
  def transform(vmaf, _opts) do
    %Message{
      data: vmaf,
      acknowledger: Broadway.NoopAcknowledger.init()
    }
  end

  # Private functions

  @spec process_vmaf_encoding(vmaf()) :: :ok | {:error, term()}
  defp process_vmaf_encoding(vmaf) do
    Logger.info("Broadway: Starting encoding for VMAF #{vmaf.id}: #{vmaf.video.path}")

    # Import necessary modules
    alias Reencodarr.AbAv1.Helper
    alias Reencodarr.{PostProcessor, Rules, Telemetry}

    try do
      # Build encoding arguments
      args = build_encode_args(vmaf)
      output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

      Logger.debug("Broadway: Starting encode with args: #{inspect(args)}")
      Logger.debug("Broadway: Output file: #{output_file}")

      # Open port and handle encoding
      port = Helper.open_port(args)

      case port do
        :error ->
          # Port creation failure is always critical
          case classify_failure(:port_error) do
            {:pause, reason} ->
              Logger.error("Broadway: Critical failure for VMAF #{vmaf.id}: #{reason}")
              Logger.error("Broadway: Pausing pipeline due to critical system issue")
              Logger.error("Broadway: Video path: #{vmaf.video.path}")

              # Notify about the failure
              notify_encoding_failure(vmaf.video, :port_error)

              # Pause the pipeline
              Reencodarr.Encoder.Broadway.Producer.pause()

              # Return :ok to Broadway since we're handling the pause manually
              :ok
          end

        _valid_port ->
          Logger.debug("Broadway: Port opened successfully: #{inspect(port)}")

          # Handle the encoding process synchronously within Broadway
          result = handle_encoding_process(port, vmaf, output_file)

          case result do
            {:ok, :success} ->
              case notify_encoding_success(vmaf.video, output_file) do
                {:ok, :success} ->
                  Logger.info(
                    "Broadway: Encoding and post-processing completed successfully for VMAF #{vmaf.id}"
                  )

                {:error, reason} ->
                  Logger.error(
                    "Broadway: Encoding succeeded but post-processing failed for VMAF #{vmaf.id}: #{reason}"
                  )
              end

              # Always return :ok for Broadway to indicate message was processed
              :ok

            {:error, exit_code} ->
              # Classify the failure to determine if we should pause or continue
              case classify_failure(exit_code) do
                {:pause, reason} ->
                  Logger.error(
                    "Broadway: Critical failure for VMAF #{vmaf.id}: #{reason} (exit code: #{exit_code})"
                  )

                  Logger.error("Broadway: Pausing pipeline due to critical system issue")

                  # Notify about the failure
                  notify_encoding_failure(vmaf.video, exit_code)

                  # Pause the pipeline
                  Reencodarr.Encoder.Broadway.Producer.pause()

                  # Still return :ok to Broadway since we're handling the pause manually
                  :ok

                {:continue, reason} ->
                  Logger.warning(
                    "Broadway: Recoverable failure for VMAF #{vmaf.id}: #{reason} (exit code: #{exit_code})"
                  )

                  # Notify about the failure and mark as failed
                  notify_encoding_failure(vmaf.video, exit_code)

                  # Continue processing - return :ok to Broadway
                  :ok
              end
          end
      end
    rescue
      exception ->
        error_message = Exception.message(exception)
        Logger.error("Broadway: Exception during encoding for VMAF #{vmaf.id}: #{error_message}")

        # Classify exception based on type
        action =
          cond do
            # System.no_memory or similar memory issues
            String.contains?(error_message, "memory") or String.contains?(error_message, "enomem") ->
              {:pause, "Memory allocation failure - system may be out of memory"}

            # File system issues
            String.contains?(error_message, "enospc") ->
              {:pause, "No space left on device"}

            # Port/process issues
            String.contains?(error_message, "port") or String.contains?(error_message, "process") ->
              {:pause, "Process management failure"}

            # Default to recoverable
            true ->
              {:continue, "Exception: #{error_message}"}
          end

        case action do
          {:pause, reason} ->
            Logger.error("Broadway: Critical exception for VMAF #{vmaf.id}: #{reason}")
            Logger.error("Broadway: Pausing pipeline due to critical system issue")

            # Notify about the failure
            notify_encoding_failure(vmaf.video, :exception)

            # Pause the pipeline
            Reencodarr.Encoder.Broadway.Producer.pause()

            # Return :ok to Broadway since we're handling the pause manually
            :ok

          {:continue, reason} ->
            Logger.warning("Broadway: Recoverable exception for VMAF #{vmaf.id}: #{reason}")

            # Notify about the failure
            notify_encoding_failure(vmaf.video, :exception)

            # Continue processing
            :ok
        end
    end
  end

  @spec handle_encoding_process(port(), vmaf(), String.t()) ::
          {:ok, :success} | {:error, integer()}
  defp handle_encoding_process(port, vmaf, output_file) do
    # Initialize state for progress tracking
    state = %{
      port: port,
      video: vmaf.video,
      vmaf: vmaf,
      output_file: output_file,
      partial_line_buffer: ""
    }

    # Process port messages until completion
    process_port_messages(state)
  end

  @spec process_port_messages(map()) :: {:ok, :success} | {:error, integer()}
  defp process_port_messages(state) do
    receive do
      {port, {:data, {:eol, data}}} when port == state.port ->
        full_line = state.partial_line_buffer <> data
        Reencodarr.ProgressParser.process_line(full_line, state)
        new_state = %{state | partial_line_buffer: ""}

        # Yield control back to the scheduler to allow Broadway metrics to update
        Process.sleep(1)
        process_port_messages(new_state)

      {port, {:data, {:noeol, message}}} when port == state.port ->
        new_buffer = state.partial_line_buffer <> message
        new_state = %{state | partial_line_buffer: new_buffer}
        process_port_messages(new_state)

      {port, {:exit_status, exit_code}} when port == state.port ->
        Logger.info("Broadway: Process exit status: #{exit_code} for VMAF #{state.vmaf.id}")

        # Check if output file was actually created
        output_exists = File.exists?(state.output_file)
        Logger.info("Broadway: Output file #{state.output_file} exists: #{output_exists}")

        # Publish completion event to PubSub
        # Only consider it success if exit code is 0 AND the output file exists
        success = exit_code == 0 and output_exists
        pubsub_result = if success, do: :success, else: {:error, exit_code}

        Phoenix.PubSub.broadcast(
          Reencodarr.PubSub,
          "encoding_events",
          {:encoding_completed, state.vmaf.id, pubsub_result}
        )

        # Return result based on exit code AND file existence
        if success do
          {:ok, :success}
        else
          {:error, exit_code}
        end
    after
      300_000 ->
        # Timeout after 5 minutes of no activity (encoding can take a long time)
        Logger.error("Broadway: Encoding timeout for VMAF #{state.vmaf.id}")
        Port.close(state.port)

        # Publish timeout event to PubSub
        Phoenix.PubSub.broadcast(
          Reencodarr.PubSub,
          "encoding_events",
          {:encoding_completed, state.vmaf.id, {:error, :timeout}}
        )

        {:error, :timeout}
    end
  end

  @spec build_encode_args(vmaf()) :: [String.t()]
  defp build_encode_args(vmaf) do
    alias Reencodarr.{Rules, AbAv1.Helper}

    base_args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "-o",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
      "-i",
      vmaf.video.path
    ]

    rule_args =
      vmaf.video
      |> Rules.apply()
      |> Enum.flat_map(fn
        {k, v} -> [to_string(k), to_string(v)]
      end)

    base_args ++ rule_args
  end

  @spec notify_encoding_success(map(), String.t()) :: {:ok, :success} | {:error, atom()}
  defp notify_encoding_success(video, output_file) do
    alias Reencodarr.{PostProcessor, Telemetry}

    # Emit telemetry event for completion
    Telemetry.emit_encoder_completed()

    # Use PostProcessor for cleanup work and return its result
    PostProcessor.process_encoding_success(video, output_file)
  end

  @spec notify_encoding_failure(map(), integer() | atom()) :: :ok
  defp notify_encoding_failure(video, exit_code) do
    alias Reencodarr.{PostProcessor, Telemetry}

    # Emit telemetry event for failure
    Telemetry.emit_encoder_failed(exit_code, video)

    # Mark the video as failed and handle cleanup
    # Convert atom exit codes to integers for database storage
    db_exit_code =
      case exit_code do
        :port_error -> -1
        :timeout -> -2
        :exception -> -3
        code when is_integer(code) -> code
        _ -> -999
      end

    PostProcessor.process_encoding_failure(video, db_exit_code)
  end

  # Failure classification - determines whether a failure should pause the pipeline
  # or just skip the current file and continue processing
  @failure_classification %{
    # System-level failures that indicate the environment is compromised
    # These should pause the pipeline to prevent further issues
    critical_failures: %{
      # Process was killed by system (OOM, etc.)
      137 => %{action: :pause, reason: "Process killed by system (likely OOM)"},
      143 => %{action: :pause, reason: "Process terminated by SIGTERM"},
      # Disk full
      28 => %{action: :pause, reason: "No space left on device"},
      # Permission denied - might be a mount issue
      13 => %{action: :pause, reason: "Permission denied - check file system permissions"},
      # I/O error - could indicate hardware issues
      5 => %{action: :pause, reason: "I/O error - possible hardware issue"},
      # Invalid command line arguments - indicates configuration issue
      2 => %{action: :pause, reason: "Invalid command line arguments - configuration error"},
      # Network timeout - may indicate systemic network issues
      110 => %{action: :pause, reason: "Network timeout - systemic network connectivity issue"},
      # Port/process creation failures
      :port_error => %{action: :pause, reason: "Failed to create encoding process"},
      :timeout => %{action: :pause, reason: "Encoding timeout - system may be overloaded"}
    },

    # File-specific failures that should skip the file but continue processing
    # These are usually due to corrupted/invalid input files
    recoverable_failures: %{
      # Standard encoding failures
      1 => %{action: :continue, reason: "Standard encoding failure (corrupted/invalid input)"},
      # File format issues
      22 => %{action: :continue, reason: "Invalid file format"},
      # Codec issues
      69 => %{action: :continue, reason: "Unsupported codec or format"}
    }
  }

  # Classifies a failure and determines the appropriate action.
  #
  # Returns:
  # - `{:pause, reason}` - Pipeline should pause due to critical system issue
  # - `{:continue, reason}` - Skip this file but continue processing
  @spec classify_failure(integer() | atom()) :: {:pause, String.t()} | {:continue, String.t()}
  defp classify_failure(exit_code) do
    cond do
      Map.has_key?(@failure_classification.critical_failures, exit_code) ->
        failure_info = @failure_classification.critical_failures[exit_code]
        {:pause, failure_info.reason}

      Map.has_key?(@failure_classification.recoverable_failures, exit_code) ->
        failure_info = @failure_classification.recoverable_failures[exit_code]
        {:continue, failure_info.reason}

      # Unknown exit codes default to continue (conservative approach)
      true ->
        {:continue, "Unknown exit code #{exit_code} - treating as recoverable failure"}
    end
  end

  @doc """
  Returns the current failure classification map for inspection or configuration.
  This can be useful for understanding which exit codes trigger which actions.
  """
  @spec get_failure_classification() :: map()
  def get_failure_classification, do: @failure_classification

  # Helper functions for testing failure classification
  if Mix.env() == :test do
    @doc false
    def test_classify_failure(exit_code), do: classify_failure(exit_code)
  end
end
