defmodule Mockchain.TransactionReceipt do
  defstruct state: nil,
            msg: nil,
            evmout: nil,
            gas_used: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil

  @type t :: %Mockchain.TransactionReceipt{
          state: Mockchain.State.t() | nil,
          msg: binary() | :ok | :revert,
          evmout: any(),
          gas_used: non_neg_integer() | nil,
          return_data: binary() | nil,
          data: binary() | nil,
          logs: []
        }

  @spec state(Mockchain.TransactionReceipt.t()) :: Mockchain.State.t()
  def state(%Mockchain.TransactionReceipt{state: state}), do: state
end
