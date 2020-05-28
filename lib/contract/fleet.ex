# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Contract.Fleet do
  @moduledoc """
    Wrapper for the FleetRegistry contract functions
    as needed by the tests
  """

  @spec set_device_whitelist(any, any, boolean) :: Chain.Transaction.t()
  def set_device_whitelist(fleet \\ Diode.fleet_address(), address, bool) when is_boolean(bool) do
    Shell.transaction(
      Diode.miner(),
      fleet,
      "SetDeviceWhitelist",
      ["address", "bool"],
      [address, bool]
    )
  end

  @spec device_whitelisted?(any, any) :: boolean
  def device_whitelisted?(fleet \\ Diode.fleet_address(), address) do
    ret = call(fleet, "deviceWhitelist", ["address"], [address], "latest")

    case :binary.decode_unsigned(ret) do
      1 -> true
      0 -> false
    end
  end

  defp call(fleet, name, types, values, blockRef) do
    {ret, _gas} = Shell.call(fleet, name, types, values, blockRef: blockRef)
    ret
  end
end
