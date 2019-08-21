defmodule Mockchain.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """

  @spec minerValue(0 | 1 | 2 | 3, <<_::160>> | Wallet.t(), any()) :: non_neg_integer
  def minerValue(type, address, blockRef) when type >= 0 and type <= 3 do
    call("MinerValue", ["uint8", "address"], [type, address], blockRef)
    |> :binary.decode_unsigned()
  end

  defp call(name, types, values, blockRef) do
    {ret, _gas} = Shell.call(Diode.registryAddress(), name, types, values, blockRef: blockRef)
    ret
  end
end
