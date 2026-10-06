defmodule ReencodarrWeb.WorkerActivity do
  @moduledoc false

  alias Reencodarr.AbAv1.WorkerSessions.Job

  @spec label(Job.t() | nil, DateTime.t()) :: String.t() | nil
  def label(job, now \\ DateTime.utc_now())
  def label(nil, _now), do: nil

  def label(%Job{} = job, now) do
    recovery = if job.recovery_action, do: " · #{recovery_label(job.recovery_action)}", else: ""
    "#{phase_label(job.phase)} · last activity #{age_label(job.last_activity_at, now)}#{recovery}"
  end

  defp phase_label(phase),
    do: phase |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp recovery_label(:warned), do: "May be stalled"
  defp recovery_label(:stop_requested), do: "Stopping stalled job"
  defp recovery_label(:stale), do: "Replaced attempt"

  defp age_label(nil, _now), do: "unknown"

  defp age_label(activity_at, now) do
    case max(DateTime.diff(now, activity_at, :second), 0) do
      seconds when seconds < 60 -> "#{seconds}s ago"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds -> "#{div(seconds, 3_600)}h ago"
    end
  end
end
