# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
defmodule Chain.TransactionReceipt do
  defstruct msg: nil,
            # state: nil,
            evmout: nil,
            gas_used: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil

  @type t :: %Chain.TransactionReceipt{
          msg: binary() | :ok | :evmc_revert,
          # state: Chain.State.t() | nil,
          evmout: any(),
          gas_used: non_neg_integer() | nil,
          return_data: binary() | nil,
          data: binary() | nil,
          logs: []
        }
end
