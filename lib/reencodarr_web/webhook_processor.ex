defmodule ReencodarrWeb.WebhookProcessor do
  @moduledoc """
  Routes webhook-triggered work through the global DbWriter.
  """

  alias Reencodarr.DbWriter

  def queue(fun) when is_function(fun, 0) do
    process(fun)
  end

  def process(fun) when is_function(fun, 0), do: DbWriter.enqueue(fun, label: :webhook)

  def reconcile_waiting_bad_file_issues(result, service_type, replacement_ref \\ %{})

  def reconcile_waiting_bad_file_issues(
        {:ok, {:ok, %Reencodarr.Media.Video{} = video}},
        service_type,
        replacement_ref
      ) do
    Reencodarr.Media.reconcile_replacement_video(video, service_type, replacement_ref)
  end

  def reconcile_waiting_bad_file_issues(
        {:ok, %Reencodarr.Media.Video{} = video},
        service_type,
        replacement_ref
      ) do
    Reencodarr.Media.reconcile_replacement_video(video, service_type, replacement_ref)
  end

  def reconcile_waiting_bad_file_issues(other_result, _service_type, _replacement_ref) do
    other_result
  end
end
