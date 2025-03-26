defmodule Slippi.WiiConsole do
  @enforce_keys [:mac, :nickname, :ip]
  @derive Jason.Encoder
  defstruct [:mac, :nickname, :ip]

  @type t :: %__MODULE__{
          mac: String.t(),
          nickname: String.t(),
          ip: String.t()
        }
end
