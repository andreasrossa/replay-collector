defmodule Slippi.WiiConsole do
  @enforce_keys [:mac, :nickname, :ip]
  defstruct [:mac, :nickname, :ip]
end
