defmodule Lucida.Http do
  @moduledoc """
  Port for the network. The client only talks to a module implementing this behaviour;
  `Lucida.Http.Httpc` is the default adapter (OTP `:httpc`), tests use a fake.
  Response header names are lowercase.
  """

  @type response :: %{status: non_neg_integer(), body: binary(), headers: [{String.t(), String.t()}]}

  @callback request(:get | :post, url :: String.t(), headers :: [{String.t(), String.t()}], body :: binary() | nil) ::
              {:ok, response()} | {:error, term()}
end
