# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Contract.Fleet do
  @moduledoc """
    Wrapper for the FleetRegistry contract functions
    as needed by the tests
  """

  def setDeviceWhiteListTx(address, bool) when is_boolean(bool) do
    Shell.transaction(
      Diode.miner(),
      Diode.fleetAddress(),
      "SetDeviceWhitelist",
      ["address", "bool"],
      [address, bool]
    )
  end

  def deviceWhitelist(address) do
    ret = call("deviceWhitelist", ["address"], [address], "latest")

    case :binary.decode_unsigned(ret) do
      1 -> true
      0 -> false
    end
  end

  defp call(name, types, values, blockRef) do
    {ret, _gas} = Shell.call(Diode.fleetAddress(), name, types, values, blockRef: blockRef)
    ret
  end
end
