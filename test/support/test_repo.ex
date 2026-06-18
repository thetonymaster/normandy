defmodule Normandy.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :normandy, adapter: Ecto.Adapters.Postgres
end
