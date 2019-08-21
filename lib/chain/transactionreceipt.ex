defmodule Chain.TransactionReceipt do
  defstruct state: nil,
            msg: nil,
            evmout: nil,
            gas_used: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil

  @type t :: %Chain.TransactionReceipt{
          state: Chain.State.t() | nil,
          msg: binary() | :ok | :revert,
          evmout: any(),
          gas_used: non_neg_integer() | nil,
          return_data: binary() | nil,
          data: binary() | nil,
          logs: []
        }

  @spec state(Chain.TransactionReceipt.t()) :: Chain.State.t()
  def state(%Chain.TransactionReceipt{state: state}), do: state
end
