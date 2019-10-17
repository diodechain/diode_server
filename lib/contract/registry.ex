defmodule Contract.Registry do
  @moduledoc """
    Wrapper for the DiodeRegistry contract functions
    as needed by the inner workings of the chain
  """

  @spec miner_value(0 | 1 | 2 | 3, <<_::160>> | Wallet.t(), any()) :: non_neg_integer
  def miner_value(type, address, block_ref) when type >= 0 and type <= 3 do
    call("miner_value", ["uint8", "address"], [type, address], block_ref)
    |> :binary.decode_unsigned()
  end

  @spec epoch(any()) :: non_neg_integer
  def epoch(block_ref) do
    call("Epoch", [], [], block_ref)
    |> :binary.decode_unsigned()
  end

  def submit_ticket_raw_tx(ticket) do
    Shell.transaction(Diode.miner(), Diode.registry_address(), "SubmitTicketRaw", ["bytes32[]"], [
      ticket
    ])
  end

  defp call(name, types, values, block_ref) do
    {ret, _gas} = Shell.call(Diode.registry_address(), name, types, values, block_ref: block_ref)
    ret
  end
end
