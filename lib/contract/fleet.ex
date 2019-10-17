defmodule Contract.Fleet do
  @moduledoc """
    Wrapper for the FleetRegistry contract functions
    as needed by the tests
  """

  def setdevice_white_listTx(address, bool) when is_boolean(bool) do
    Shell.transaction(
      Diode.miner(),
      Diode.fleet_address(),
      "Setdevice_white_list",
      ["address", "bool"],
      [address, bool]
    )
  end

  def device_white_list(address) do
    ret = call("device_white_list", ["address"], [address], "latest")

    case :binary.decode_unsigned(ret) do
      1 -> true
      0 -> false
    end
  end

  defp call(name, types, values, block_ref) do
    {ret, _gas} = Shell.call(Diode.fleet_address(), name, types, values, block_ref: block_ref)
    ret
  end
end
