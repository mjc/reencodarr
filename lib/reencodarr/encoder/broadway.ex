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
  alias Reencodarr.AbAv1.Helper
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.BroadwayConfig
  alias Reencodarr.{PostProcessor, Telemetry}

  @typedoc "VMAF struct for encoding processing"
  @type vmaf :: %{id: integer(), video: map()}

  @typedoc "Broadway pipeline configuration"
  @type config :: keyword()

  # Configuration constants
  @default_config [
    rate_limit_messages: 5,
    rate_limit_interval: 1_000,
    # 30 days (1 month) default timeout for encoding operations
    encoding_timeout: 2_592_000_000
  ]

  @doc """
  Start the Broadway pipeline with configurable options.

  ## Options
    * `:rate_limit_messages` - Number of messages allowed per interval (default: 5)
    * `:rate_limit_interval` - Rate limit interval in milliseconds (default: 1000)
    * `:batch_size` - Number of messages per batch (default: 1)
    * `:batch_timeout` - Batch timeout in milliseconds (default: 10000)
    * `:encoding_timeout` - Encoding timeout in milliseconds (default: 2592000000 = 30 days)

  ## Examples
      iex> Reencodarr.Encoder.Broadway.start_link([])
      {:ok, pid}

      iex> Reencodarr.Encoder.Broadway.start_link([rate_limit_messages: 3])
      {:ok, pid}

      iex> Reencodarr.Encoder.Broadway.start_link([encoding_timeout: 14400000])  # 4 hours
      {:ok, pid}
  """
  @spec start_link(config()) :: GenServer.on_start()
  def start_link(opts) do
    config = BroadwayConfig.merge_config(__MODULE__, @default_config, opts)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Producer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: BroadwayConfig.rate_limiting_config(config)
      ],
      processors: BroadwayConfig.processor_config(),
      context: %{
        encoding_timeout: config[:encoding_timeout]
      }
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
    case Producer.add_vmaf(vmaf) do
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
      Producer.running?()
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
    Producer.pause()
  end

  @doc """
  Resume the encoder pipeline.

  ## Examples
      iex> Reencodarr.Encoder.Broadway.resume()
      :ok
  """
  @spec resume() :: :ok | {:error, term()}
  def resume do
    Producer.resume()
  end

  @doc """
  Start the encoder pipeline.

  Alias for `resume/0` to maintain API compatibility.
  """
  @spec start() :: :ok | {:error, term()}
  def start, do: resume()

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, context) do
    # Start encoding asynchronously but wait for completion to maintain single-concurrency
    task =
      Task.async(fn ->
        process_vmaf_encoding(message.data, context)
      end)

    # Wait for the task to complete - process_vmaf_encoding handles all logging internally
    result =
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

    # CRITICAL: Notify producer that message processing is complete and ready for next demand
    Logger.debug(
      "Broadway: Message processing complete for VMAF #{message.data.id} - notifying producer"
    )

    Producer.dispatch_available()

    result
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

  @spec process_vmaf_encoding(vmaf(), map()) :: :ok | {:error, term()}
  defp process_vmaf_encoding(vmaf, context) do
    # Build encoding arguments
    args = build_encode_args(vmaf)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

    # Open port and handle encoding
    port = Helper.open_port(args)
    handle_encoding_port(port, vmaf, output_file, context)
  rescue
    exception ->
      handle_encoding_exception(exception, vmaf)
  end

  defp handle_encoding_port(:error, vmaf, _output_file, _context) do
    # Port creation failure is always critical
    case classify_failure(:port_error) do
      {:pause, reason} ->
        Logger.error("Broadway: Critical failure for VMAF #{vmaf.id}: #{reason}")
        Logger.error("Broadway: Pausing pipeline due to critical system issue")
        Logger.error("Broadway: Video path: #{vmaf.video.path}")

        # Notify about the failure
        notify_encoding_failure(vmaf.video, :port_error)

        # Pause the pipeline
        Producer.pause()

        # Return :ok to Broadway since we're handling the pause manually
        :ok
    end
  end

  defp handle_encoding_port(port, vmaf, output_file, context) do
    # Handle the encoding process synchronously within Broadway
    # Default to 30 days
    encoding_timeout = Map.get(context, :encoding_timeout, 2_592_000_000)
    result = handle_encoding_process(port, vmaf, output_file, encoding_timeout)

    handle_encoding_result(result, vmaf, output_file)
  end

  defp handle_encoding_result({:ok, :success}, vmaf, output_file) do
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
  end

  defp handle_encoding_result({:error, exit_code}, vmaf, _output_file) do
    handle_encoding_error(vmaf, exit_code, %{})
  end

  defp handle_encoding_result({:error, exit_code, context}, vmaf, _output_file) do
    handle_encoding_error(vmaf, exit_code, context)
  end

  defp handle_encoding_error(vmaf, exit_code, context) do
    # Classify the failure to determine if we should pause or continue
    case classify_failure(exit_code) do
      {:pause, reason} ->
        handle_critical_encoding_failure(vmaf, exit_code, reason, context)

      {:continue, reason} ->
        handle_recoverable_encoding_failure(vmaf, exit_code, reason, context)
    end
  end

  defp handle_critical_encoding_failure(vmaf, exit_code, reason, context) do
    Logger.error("Broadway: ENTERING handle_critical_encoding_failure")

    Logger.error(
      "Broadway: Critical failure for VMAF #{vmaf.id}: #{reason} (exit code: #{exit_code})"
    )

    Logger.error("Broadway: Pausing pipeline due to critical system issue - #{reason}")
    Logger.error("Broadway: Video path: #{vmaf.video.path}")

    # Build enhanced context for failure tracking
    enhanced_context =
      if Map.has_key?(context, :args) do
        Reencodarr.FailureTracker.build_command_context(context.args, context[:output], context)
      else
        context
      end

    # Notify about the failure with enhanced context
    notify_encoding_failure(vmaf.video, exit_code, enhanced_context)

    # Pause the pipeline
    Logger.error("Broadway: PAUSING ENCODER - Critical failure with exit code #{exit_code}")
    Producer.pause()

    # Still return :ok to Broadway since we're handling the pause manually
    :ok
  end

  defp handle_recoverable_encoding_failure(vmaf, exit_code, reason, context) do
    Logger.warning("Broadway: ENTERING handle_recoverable_encoding_failure")

    Logger.warning(
      "Broadway: Recoverable failure for VMAF #{vmaf.id}: #{reason} (exit code: #{exit_code})"
    )

    Logger.warning("Broadway: This should NOT pause the pipeline - continuing processing")

    # Build enhanced context for failure tracking
    enhanced_context =
      if Map.has_key?(context, :args) do
        Reencodarr.FailureTracker.build_command_context(context.args, context[:output], context)
      else
        context
      end

    # Notify about the failure and mark as failed with enhanced context
    notify_encoding_failure(vmaf.video, exit_code, enhanced_context)

    # Continue processing - return :ok to Broadway
    Logger.warning(
      "Broadway: EXITING handle_recoverable_encoding_failure - returning :ok (no pause)"
    )

    :ok
  end

  defp handle_encoding_exception(exception, vmaf) do
    error_message = Exception.message(exception)
    Logger.error("Broadway: Exception during encoding for VMAF #{vmaf.id}: #{error_message}")

    # Classify exception based on type
    action = classify_exception_action(error_message)

    case action do
      {:pause, reason} ->
        handle_critical_exception(vmaf, reason)

      {:continue, reason} ->
        handle_recoverable_exception(vmaf, reason)
    end
  end

  defp classify_exception_action(error_message) do
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
  end

  defp handle_critical_exception(vmaf, reason) do
    Logger.error("Broadway: Critical exception for VMAF #{vmaf.id}: #{reason}")
    Logger.error("Broadway: Pausing pipeline due to critical system issue")

    # Notify about the failure
    notify_encoding_failure(vmaf.video, :exception)

    # Pause the pipeline
    Producer.pause()

    # Return :ok to Broadway since we're handling the pause manually
    :ok
  end

  defp handle_recoverable_exception(vmaf, reason) do
    Logger.warning("Broadway: Recoverable exception for VMAF #{vmaf.id}: #{reason}")

    # Notify about the failure
    notify_encoding_failure(vmaf.video, :exception)

    # Continue processing
    :ok
  end

  @spec handle_encoding_process(port(), vmaf(), String.t(), integer()) ::
          {:ok, :success} | {:error, integer()}
  defp handle_encoding_process(port, vmaf, output_file, encoding_timeout) do
    # Initialize state for progress tracking
    state = %{
      port: port,
      video: vmaf.video,
      vmaf: vmaf,
      output_file: output_file,
      partial_line_buffer: "",
      output_buffer: []
    }

    # Process port messages until completion
    process_port_messages(state, encoding_timeout)
  end

  @spec process_port_messages(map(), integer()) :: {:ok, :success} | {:error, integer()}
  defp process_port_messages(state, encoding_timeout) do
    receive do
      {port, {:data, {:eol, data}}} when port == state.port ->
        full_line = state.partial_line_buffer <> data
        Reencodarr.ProgressParser.process_line(full_line, state)

        # Add line to output buffer for failure tracking
        new_output_buffer = [full_line | state.output_buffer]
        new_state = %{state | partial_line_buffer: "", output_buffer: new_output_buffer}

        # Yield control back to the scheduler to allow Broadway metrics to update
        Process.sleep(1)
        process_port_messages(new_state, encoding_timeout)

      {port, {:data, {:noeol, message}}} when port == state.port ->
        new_buffer = state.partial_line_buffer <> message
        new_state = %{state | partial_line_buffer: new_buffer}
        process_port_messages(new_state, encoding_timeout)

      {port, {:exit_status, exit_code}} when port == state.port ->
        Logger.debug("Broadway: Process exit status: #{exit_code} for VMAF #{state.vmaf.id}")

        # Check if output file was actually created
        output_exists = File.exists?(state.output_file)
        Logger.debug("Broadway: Output file #{state.output_file} exists: #{output_exists}")

        # Return result based on exit code AND file existence
        if exit_code == 0 and output_exists do
          {:ok, :success}
        else
          # Include output buffer and args in error for failure tracking
          full_output = state.output_buffer |> Enum.reverse() |> Enum.join("\n")
          {:error, exit_code, %{output: full_output, args: build_encode_args(state.vmaf)}}
        end
    after
      encoding_timeout ->
        # Timeout after configured duration (default 30 days for very large files)
        # Convert to days for logging
        timeout_days = encoding_timeout / 86_400_000

        Logger.error(
          "Broadway: Encoding timeout for VMAF #{state.vmaf.id} after #{timeout_days} days"
        )

        Port.close(state.port)

        # Include output buffer for timeout failures
        full_output = state.output_buffer |> Enum.reverse() |> Enum.join("\n")
        {:error, :timeout, %{output: full_output, args: build_encode_args(state.vmaf)}}
    end
  end

  @spec build_encode_args(vmaf()) :: [String.t()]
  defp build_encode_args(vmaf) do
    base_args = [
      "encode",
      "--crf",
      to_string(vmaf.crf),
      "--output",
      Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv"),
      "--input",
      vmaf.video.path
    ]

    # Get rule-based arguments from centralized Rules module
    # Extract VMAF params for use in Rules.build_args
    vmaf_params = if vmaf.params && is_list(vmaf.params), do: vmaf.params, else: []

    # Use the 4-arity version that handles deduplication properly
    result_args = Reencodarr.Rules.build_args(vmaf.video, :encode, vmaf_params, base_args)

    result_args
  end

  # Test helper function to expose build_encode_args for testing
  if Mix.env() == :test do
    def build_encode_args_for_test(vmaf), do: build_encode_args(vmaf)
    def filter_input_output_args_for_test(args), do: filter_input_output_args(args)

    # Filter out input/output arguments and their values from a list of arguments
    defp filter_input_output_args(args) do
      {filtered, _expecting_value} =
        Enum.reduce(args, {[], nil}, fn arg, {acc, expecting_value} ->
          process_arg_filter(arg, acc, expecting_value)
        end)

      Enum.reverse(filtered)
    end

    defp process_arg_filter(arg, acc, expecting_value) do
      cond do
        expecting_value -> handle_expected_value(arg, acc, expecting_value)
        input_output_flag?(arg) -> {acc, arg}
        true -> {[arg | acc], nil}
      end
    end

    defp handle_expected_value(arg, acc, expecting_value) do
      if expecting_value in ["--input", "-i", "--output", "-o"] do
        {acc, nil}
      else
        {[arg | acc], nil}
      end
    end

    defp input_output_flag?(arg) do
      arg in ["--input", "-i", "--output", "-o"]
    end
  end

  @spec notify_encoding_success(map(), String.t()) :: {:ok, :success} | {:error, atom()}
  defp notify_encoding_success(video, output_file) do
    # Emit telemetry event for completion
    Telemetry.emit_encoder_completed()

    # Use PostProcessor for cleanup work and return its result
    PostProcessor.process_encoding_success(video, output_file)
  end

  @spec notify_encoding_failure(map(), integer() | atom(), map()) :: :ok
  defp notify_encoding_failure(video, exit_code, context \\ %{}) do
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

    PostProcessor.process_encoding_failure(video, db_exit_code, context)
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
      # Invalid command line arguments - indicates configuration issue
      2 => %{action: :pause, reason: "Invalid command line arguments - configuration error"},
      # I/O error - could indicate hardware issues
      5 => %{action: :pause, reason: "I/O error - possible hardware issue"},
      # Disk full - definitely systemic
      28 => %{action: :pause, reason: "No space left on device"},
      # Network timeout - may indicate systemic network issues
      110 => %{action: :pause, reason: "Network timeout - systemic network connectivity issue"},
      # Port/process creation failures - systemic
      :port_error => %{action: :pause, reason: "Failed to create encoding process"},
      :timeout => %{action: :pause, reason: "Encoding timeout - system may be overloaded"}
    },

    # File-specific failures that should skip the file but continue processing
    # These are usually due to corrupted/invalid input files or file-specific issues
    recoverable_failures: %{
      # Standard encoding failures
      1 => %{action: :continue, reason: "Standard encoding failure (corrupted/invalid input)"},
      # Permission denied - might be file-specific permissions
      13 => %{action: :continue, reason: "Permission denied (file-specific permissions)"},
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
    Logger.debug("Broadway: classify_failure called with exit_code: #{inspect(exit_code)}")

    result =
      cond do
        Map.has_key?(@failure_classification.critical_failures, exit_code) ->
          failure_info = @failure_classification.critical_failures[exit_code]

          Logger.debug(
            "Broadway: Exit code #{exit_code} classified as CRITICAL: #{failure_info.reason}"
          )

          {:pause, failure_info.reason}

        Map.has_key?(@failure_classification.recoverable_failures, exit_code) ->
          failure_info = @failure_classification.recoverable_failures[exit_code]

          Logger.debug(
            "Broadway: Exit code #{exit_code} classified as RECOVERABLE: #{failure_info.reason}"
          )

          {:continue, failure_info.reason}

        # Unknown exit codes default to continue (conservative approach)
        true ->
          Logger.debug(
            "Broadway: Exit code #{exit_code} classified as UNKNOWN - treating as recoverable"
          )

          {:continue, "Unknown exit code #{exit_code} - treating as recoverable failure"}
      end

    Logger.debug("Broadway: classify_failure(#{exit_code}) -> #{inspect(result)}")
    result
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
