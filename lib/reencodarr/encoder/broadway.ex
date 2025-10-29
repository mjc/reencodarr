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
  alias Reencodarr.AbAv1.ProgressParser
  alias Reencodarr.Dashboard.Events
  alias Reencodarr.Encoder.Broadway.Producer
  alias Reencodarr.PostProcessor

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
    app_config = Application.get_env(:reencodarr, __MODULE__, [])
    config = @default_config |> Keyword.merge(app_config) |> Keyword.merge(opts)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Producer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: [
          # Use normal rate limiting - pause/resume controlled by producer state
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
      context: %{
        encoding_timeout: config[:encoding_timeout],
        rate_limit_messages: config[:rate_limit_messages],
        rate_limit_interval: config[:rate_limit_interval]
      }
    )
  end

  @doc """
  Add a VMAF to the pipeline for encoding processing.

  ## Parameters
    * `vmaf` - VMAF struct containing id and video data

  @doc \"""
  Process a VMAF - now handled automatically by Broadway polling.
  This function is a no-op for backwards compatibility.
  """
  @spec process_vmaf(vmaf()) :: :ok
  def process_vmaf(_vmaf), do: :ok

  @doc """
  Check if the encoder pipeline is running (always true now).
  """
  @spec running?() :: boolean()
  def running?, do: true

  @doc """
  Pause the encoder pipeline - no-op, pipelines always run now.
  """
  @spec pause() :: :ok
  def pause, do: :ok

  @doc """
  Resume the encoder pipeline - no-op, pipelines always run now.
  """
  @spec resume() :: :ok
  def resume, do: :ok

  @doc """
  Start the encoder pipeline - alias for resume, no-op now.
  """
  @spec start() :: :ok
  def start, do: :ok

  # Broadway callbacks

  @impl Broadway
  def handle_message(_processor_name, message, context) do
    # Start encoding asynchronously but wait for completion to maintain single-concurrency
    task =
      Task.async(fn ->
        process_vmaf_encoding(message.data, context)
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

  @spec process_vmaf_encoding(vmaf(), map()) :: :ok | {:error, term()}
  defp process_vmaf_encoding(vmaf, context) do
    Logger.info("Broadway: Starting encoding for VMAF #{vmaf.id}: #{vmaf.video.path}")

    # Broadcast initial encoding progress at 0%
    Events.broadcast_event(:encoding_started, %{
      video_id: vmaf.video.id,
      filename: Path.basename(vmaf.video.path)
    })

    # Build encoding arguments
    args = build_encode_args(vmaf)
    output_file = Path.join(Helper.temp_dir(), "#{vmaf.video.id}.mkv")

    Logger.debug("Broadway: Starting encode with args: #{inspect(args)}")
    Logger.debug("Broadway: Output file: #{output_file}")

    # Open port and handle encoding
    port = Helper.open_port(args)
    handle_encoding_port(port, vmaf, output_file, context)
  end

  defp handle_encoding_port(:error, vmaf, _output_file, _context) do
    # Port creation failure is always critical
    case classify_failure(:port_error) do
      {:pause, reason} ->
        Logger.error("Broadway: Critical failure for VMAF #{vmaf.id}: #{reason}")
        Logger.error("Broadway: Critical system issue, but continuing (pipelines always run)")
        Logger.error("Broadway: Video path: #{vmaf.video.path}")

        # Notify about the failure
        notify_encoding_failure(vmaf.video, :port_error)

        # Return :ok to Broadway - we continue processing
        :ok
    end
  end

  defp handle_encoding_port(port, vmaf, output_file, context) do
    Logger.debug("Broadway: Port opened successfully: #{inspect(port)}")

    # Handle the encoding process synchronously within Broadway
    # Default to 30 days
    encoding_timeout = Map.get(context, :encoding_timeout, 2_592_000_000)
    result = handle_encoding_process(port, vmaf, output_file, encoding_timeout)

    handle_encoding_result(result, vmaf, output_file)
  end

  @spec handle_encoding_result(
          {:ok, :success} | {:error, integer()} | {:error, integer(), map()},
          vmaf(),
          binary()
        ) :: :ok
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

    # Notify other pipelines that work is available
    Producer.dispatch_available()

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

    Logger.error(
      "Broadway: Critical system issue - #{reason}, but continuing (pipelines always run)"
    )

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

    # Return :ok to Broadway - we continue processing
    :ok
  end

  defp handle_recoverable_encoding_failure(vmaf, exit_code, reason, context) do
    Logger.debug("entering recoverable encoding failure handler")

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

  @spec handle_encoding_process(port(), vmaf(), String.t(), integer()) ::
          {:ok, :success} | {:error, integer()}
  defp handle_encoding_process(port, vmaf, output_file, encoding_timeout) do
    # Set up state for port message processing
    state = %{
      port: port,
      vmaf: vmaf,
      # Add video directly to state for ProgressParser compatibility
      video: vmaf.video,
      output_file: output_file,
      partial_line_buffer: "",
      output_buffer: []
    }

    process_port_messages(state, encoding_timeout)
  end

  @spec process_port_messages(map(), integer()) :: {:ok, :success} | {:error, integer()}
  defp process_port_messages(state, encoding_timeout) do
    receive do
      {port, {:data, {:eol, data}}} when port == state.port ->
        full_line = state.partial_line_buffer <> data
        ProgressParser.process_line(full_line, state)

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
        Logger.info("Broadway: Process exit status: #{exit_code} for VMAF #{state.vmaf.id}")

        # Check if output file was actually created
        output_exists = File.exists?(state.output_file)
        Logger.info("Broadway: Output file #{state.output_file} exists: #{output_exists}")

        # Publish completion event to PubSub
        # Only consider it success if exit code is 0 AND the output file exists
        success = exit_code == 0 and output_exists
        result = if success, do: :success, else: {:error, exit_code}

        # Broadcast encoding completion using centralized Events system
        Events.broadcast_event(:encoding_completed, %{
          vmaf_id: state.vmaf.id,
          result: result,
          success: success,
          exit_code: exit_code
        })

        # Return result based on exit code AND file existence
        if success do
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

        # Broadcast encoding timeout using centralized Events system
        Events.broadcast_event(:encoding_completed, %{
          vmaf_id: state.vmaf.id,
          result: {:error, :timeout},
          success: false,
          timeout: true
        })

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
    vmaf_params = extract_vmaf_params(vmaf)

    Logger.debug("build_encode_args details",
      vmaf_id: vmaf.id,
      base_args: base_args,
      vmaf_params: vmaf_params
    )

    # Use the 4-arity version that handles deduplication properly
    result_args = Reencodarr.Rules.build_args(vmaf.video, :encode, vmaf_params, base_args)

    Logger.debug("build_encode_args result", result_args: result_args)

    # Count duplicates for debugging
    input_count = Enum.count(result_args, &(&1 == "--input"))
    path_count = Enum.count(result_args, &(&1 == vmaf.video.path))

    Logger.debug("argument validation",
      input_count: input_count,
      path_count: path_count
    )

    if path_count > 1 do
      Logger.error("Broadway: build_encode_args ERROR - Duplicate path detected!")

      # Find positions of the path
      path_positions =
        result_args
        |> Enum.with_index()
        |> Enum.filter(fn {arg, _idx} -> arg == vmaf.video.path end)
        |> Enum.map(fn {_arg, idx} -> idx end)

      Logger.error(
        "Broadway: build_encode_args ERROR - Path appears at positions: #{inspect(path_positions)}"
      )

      # Show context around each occurrence
      Enum.each(path_positions, fn pos ->
        start_pos = max(0, pos - 2)
        end_pos = min(length(result_args) - 1, pos + 2)
        context = Enum.slice(result_args, start_pos..end_pos)

        Logger.error(
          "Broadway: build_encode_args ERROR - Position #{pos} context: #{inspect(context)}"
        )
      end)
    end

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
    # Use PostProcessor for cleanup work and return its result
    PostProcessor.process_encoding_success(video, output_file)
  end

  @spec notify_encoding_failure(map(), integer() | atom(), map()) :: :ok
  defp notify_encoding_failure(video, exit_code, context \\ %{}) do
    # Mark the video as failed and handle cleanup
    # Convert atom exit codes to integers for database storage
    db_exit_code =
      case exit_code do
        :port_error -> -1
        :exception -> -3
        # For integer exit codes, use them directly
        code when is_integer(code) -> code
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
      :exception => %{action: :pause, reason: "Unexpected exception during encoding"}
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
  @spec classify_failure(integer() | atom()) :: {:pause, binary()} | {:continue, binary()}
  defp classify_failure(exit_code) do
    Logger.debug("classifying failure", exit_code: exit_code)

    result =
      case {Map.get(@failure_classification.critical_failures, exit_code),
            Map.get(@failure_classification.recoverable_failures, exit_code)} do
        {failure_info, _} when is_map(failure_info) ->
          Logger.info(
            "Broadway: Exit code #{exit_code} classified as CRITICAL: #{failure_info.reason}"
          )

          {:pause, failure_info.reason}

        {_, failure_info} when is_map(failure_info) ->
          Logger.info(
            "Broadway: Exit code #{exit_code} classified as RECOVERABLE: #{failure_info.reason}"
          )

          {:continue, failure_info.reason}

        {_, _} ->
          Logger.info(
            "Broadway: Exit code #{exit_code} classified as UNKNOWN - treating as recoverable"
          )

          {:continue, "Unknown exit code #{exit_code} - treating as recoverable failure"}
      end

    Logger.debug("failure classification result", exit_code: exit_code, result: result)
    result
  end

  @doc """
  Returns the current failure classification map for inspection or configuration.
  This can be useful for understanding which exit codes trigger which actions.
  """
  @spec get_failure_classification() :: map()
  def get_failure_classification, do: @failure_classification

  # Helper function to extract VMAF params with proper pattern matching
  defp extract_vmaf_params(%{params: params}) when is_list(params), do: params
  defp extract_vmaf_params(_), do: []

  # Helper functions for testing failure classification and encoding paths
  if Mix.env() == :test do
    @doc false
    def test_classify_failure(exit_code), do: classify_failure(exit_code)

    @doc false
    def test_handle_encoding_result(result, vmaf, output_file),
      do: handle_encoding_result(result, vmaf, output_file)

    @doc false
    def test_handle_encoding_error(vmaf, exit_code, context),
      do: handle_encoding_error(vmaf, exit_code, context)

    @doc false
    def test_notify_encoding_success(video, output_file),
      do: notify_encoding_success(video, output_file)

    @doc false
    def test_handle_encoding_process(port, vmaf, output_file, timeout),
      do: handle_encoding_process(port, vmaf, output_file, timeout)

    @doc false
    def test_process_port_messages(messages, state), do: process_port_messages(messages, state)
  end
end
