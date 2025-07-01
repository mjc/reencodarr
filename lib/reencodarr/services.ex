defmodule Reencodarr.Services do
  @moduledoc """
  This module is responsible for communicating with external services.
  """
  alias Reencodarr.Repo
  alias Reencodarr.Services.Config
  alias Reencodarr.Services.Radarr
  alias Reencodarr.Services.Sonarr

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

  @doc "Gets the Sonarr config or raises if not found."
  @spec get_sonarr_config! :: Config.t()
  def get_sonarr_config! do
    Repo.get_by!(Config, service_type: :sonarr)
  end

  @doc "Gets the Sonarr config."
  @spec get_sonarr_config :: {:ok, Config.t()} | {:error, :not_found}
  def get_sonarr_config do
    case Repo.get_by(Config, service_type: :sonarr) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

  @doc "Gets the Radarr config or raises if not found."
  @spec get_radarr_config! :: Config.t()
  def get_radarr_config! do
    Repo.get_by!(Config, service_type: :radarr)
  end

  @doc "Gets the Radarr config."
  @spec get_radarr_config :: {:ok, Config.t()} | {:error, :not_found}
  def get_radarr_config do
    case Repo.get_by(Config, service_type: :radarr) do
      nil -> {:error, :not_found}
      config -> {:ok, config}
    end
  end

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

  @doc "Fetches the Sonarr system status."
  @spec get_sonarr_status :: {:ok, any()} | {:error, any()}
  def get_sonarr_status, do: Sonarr.system_status()

  @doc "Fetches all shows from Sonarr."
  def get_shows, do: Sonarr.get_shows()

  @doc "Fetches all episode files for a given show."
  def get_episode_files(show_id), do: Sonarr.get_episode_files(show_id)

  @doc "Fetches all movies from Radarr."
  def get_movies, do: Radarr.get_movies()

  @doc "Fetches all movie files for a given movie."
  def get_movie_files(movie_id), do: Radarr.get_movie_files(movie_id)
end
