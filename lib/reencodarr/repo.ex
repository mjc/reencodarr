defmodule Reencodarr.Repo do
  use Ecto.Repo,
    otp_app: :reencodarr,
    adapter: Ecto.Adapters.Postgres
end
