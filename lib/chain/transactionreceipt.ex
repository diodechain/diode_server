defmodule Chain.transaction_receipt do
  defstruct msg: nil,
            # state: nil,
            evmout: nil,
            gas_used: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil

  @type t :: %Chain.transaction_receipt{
          msg: binary() | :ok | :revert,
          # state: Chain.State.t() | nil,
          evmout: any(),
          gas_used: non_neg_integer() | nil,
          return_data: binary() | nil,
          data: binary() | nil,
          logs: []
        }
end
