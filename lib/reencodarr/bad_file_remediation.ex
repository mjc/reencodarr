defmodule Reencodarr.BadFileRemediation do
  @moduledoc false

  alias Reencodarr.Media
  alias Reencodarr.Media.BadFileIssue
  alias Reencodarr.Services.{Radarr, Sonarr}

  @spec process_next_issue(keyword()) :: :idle | {:ok, BadFileIssue.t()} | {:error, term()}
  def process_next_issue(opts \\ []) do
    service_type = Keyword.get(opts, :service_type, :all)

    case Media.next_queued_bad_file_issue(service_type) do
      nil ->
        :idle

      %BadFileIssue{} = issue ->
        process_issue(issue, opts)
    end
  end

  @spec process_issue(BadFileIssue.t(), keyword()) :: {:ok, BadFileIssue.t()} | {:error, term()}
  def process_issue(%BadFileIssue{} = issue, opts \\ []) do
    already_fixed_fun = Keyword.get(opts, :already_fixed_fun, fn _video, _issue -> false end)

    with {:ok, current_issue} <- refresh_issue(issue.id),
         {:ok, processing_issue} <- ensure_processing_issue(current_issue) do
      resolve_issue_processing(processing_issue, already_fixed_fun)
    end
  end

  defp resolve_issue_processing(processing_issue, already_fixed_fun) do
    video = processing_issue.video

    if already_fixed_fun.(video, processing_issue) do
      transition_issue(processing_issue.id, :replaced_clean)
    else
      remediate_video(video)
      |> complete_remediation_transition(processing_issue.id)
    end
  end

  defp complete_remediation_transition(:ok, issue_id),
    do: transition_issue(issue_id, :waiting_for_replacement)

  defp complete_remediation_transition({:error, reason}, issue_id) do
    transition_issue(issue_id, :failed) |> tag_error(reason)
  end

  defp remediate_video(%{service_type: :sonarr, service_id: service_id}) do
    with {:ok, file_id} <- parse_positive_integer(service_id),
         {:ok, %{body: episode_file}} <- Sonarr.get_episode_file(file_id),
         {:ok, %{body: episodes}} <- Sonarr.get_episodes_by_file(file_id),
         {:ok, episode_ids} <- extract_ids(episodes),
         {:ok, _response} <- Sonarr.set_episodes_monitored(episode_ids, true),
         {:ok, _response} <- Sonarr.delete_episode_file(episode_file["id"] || file_id),
         {:ok, _response} <- Sonarr.trigger_episode_search(episode_ids) do
      :ok
    end
  end

  defp remediate_video(%{service_type: :radarr, service_id: service_id}) do
    with {:ok, file_id} <- parse_positive_integer(service_id),
         {:ok, %{body: movie_file}} <- Radarr.get_movie_file(file_id),
         {:ok, movie_id} <- parse_positive_integer(movie_file["movieId"]),
         {:ok, _response} <- Radarr.set_movie_monitored(movie_id, true),
         {:ok, _response} <- Radarr.delete_movie_file(file_id),
         {:ok, _response} <- Radarr.trigger_movie_search(movie_id) do
      :ok
    end
  end

  defp remediate_video(_video), do: {:error, :unsupported_service}

  defp extract_ids(items) when is_list(items) and items != [] do
    ids =
      Enum.map(items, fn item -> item["id"] end)

    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) do
      {:ok, ids}
    else
      {:error, :invalid_item_ids}
    end
  end

  defp extract_ids(_items), do: {:error, :invalid_item_ids}

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} when int_value > 0 -> {:ok, int_value}
      _other -> {:error, :invalid_service_id}
    end
  end

  defp parse_positive_integer(_value), do: {:error, :invalid_service_id}

  defp refresh_issue(issue_id) when is_integer(issue_id) do
    case Media.fetch_bad_file_issue(issue_id) do
      {:ok, issue} -> {:ok, issue}
      :not_found -> {:error, :issue_not_found}
    end
  end

  defp ensure_processing_issue(%BadFileIssue{status: :processing} = issue), do: {:ok, issue}

  defp ensure_processing_issue(%BadFileIssue{status: :waiting_for_replacement} = issue),
    do: {:ok, issue}

  defp ensure_processing_issue(%BadFileIssue{} = issue),
    do: transition_issue(issue.id, :processing)

  defp transition_issue(issue_id, status) when is_integer(issue_id) do
    with {:ok, current_issue} <- refresh_issue(issue_id) do
      Media.update_bad_file_issue_status(current_issue, status)
    end
  end

  defp tag_error({:ok, issue}, reason), do: {:error, {issue, reason}}
  defp tag_error({:error, error}, reason), do: {:error, {error, reason}}
end
