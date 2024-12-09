defmodule Reencodarr.Services do
  @moduledoc """
  This module is responsible for communicating with external services.
  """
  require Logger
  alias Reencodarr.Repo
  alias Reencodarr.Services.Config

  def test_sonarr_authorization(api_key, base_url) do
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

  @doc """
  Returns the list of configs.

  ## Examples

      iex> list_configs()
      [%Config{}, ...]

  """
  def list_configs do
    Repo.all(Config)
  end

  @doc """
  Gets a single config.

  Raises `Ecto.NoResultsError` if the Config does not exist.

  ## Examples

      iex> get_config!(123)
      %Config{}

      iex> get_config!(456)
      ** (Ecto.NoResultsError)

  """
  def get_config!(id), do: Repo.get!(Config, id)

  @doc """
  Creates a config.

  ## Examples

      iex> create_config(%{field: value})
      {:ok, %Config{}}

      iex> create_config(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_config(attrs \\ %{}) do
    %Config{}
    |> Config.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a config.

  ## Examples

      iex> update_config(config, %{field: new_value})
      {:ok, %Config{}}

      iex> update_config(config, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_config(%Config{} = config, attrs) do
    config
    |> Config.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a config.

  ## Examples

      iex> delete_config(config)
      {:ok, %Config{}}

      iex> delete_config(config)
      {:error, %Ecto.Changeset{}}

  """
  def delete_config(%Config{} = config) do
    Repo.delete(config)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking config changes.

  ## Examples

      iex> change_config(config)
      %Ecto.Changeset{data: %Config{}}

  """
  def change_config(%Config{} = config, attrs \\ %{}) do
    Config.changeset(config, attrs)
  end
end
