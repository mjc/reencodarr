defmodule Reencodarr.Services do
  @moduledoc """
    This module is responsible for communicating with external services.
  """

  def test_sonarr_authorization(api_key, base_url) do
    url = "#{base_url}/api/v3/system/status"
    headers = [{"X-Api-Key", api_key}]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200} = req} ->
        dbg(req)
        {:ok, "Authorization successful"}

      {:ok, %Req.Response{status: status_code}} ->
        {:error, "Authorization failed with status code #{status_code}"}

      {:error, %Req.HTTPError{reason: reason}} ->
        {:error, "Authorization failed with reason #{reason}"}
    end
  end
end
