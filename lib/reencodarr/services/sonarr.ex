defmodule Reencodarr.Services.Sonarr do
  @moduledoc """
  This module is responsible for communicating with the Sonarr API.
  """
  require Logger

  def test_authorization(api_key, base_url) do
    url = "#{base_url}/api/v3/system/status"
    headers = [{"X-Api-Key", api_key}]

    with {:ok, %Req.Response{status: 200, body: %{"version" => version}}} <-
           Req.get(url, headers: headers) do
      Logger.info("Sonarr version: #{version}")
      {:ok, "Authorization successful"}
    else
      {:ok, %Req.Response{status: status_code}} ->
        {:error, "Authorization failed with status code #{status_code}"}

      {:error, %Req.HTTPError{reason: reason}} ->
        {:error, "Authorization failed with reason #{reason}"}
    end
  end
end
