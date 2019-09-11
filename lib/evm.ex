defmodule Evm do
  @moduledoc """
  Wrapper around epoch/aevm
  """
  alias Chain.Transaction

  defmodule State do
    defstruct chain_state: nil,
              from: nil,
              origin: nil,
              tx: nil,
              code: "",
              trace: false,
              coinbase: nil,
              difficulty: 0,
              gasLimit: 0,
              timestamp: 0,
              number: 0,
              internal: false,
              selfdestructs: []

    @spec store(Evm.State.t()) :: MerkleTree.merkle()
    def store(%State{chain_state: st} = state) do
      Chain.State.ensure_account(st, address(state)).storageRoot
    end

    def code(%State{code: code}), do: code
    def coinbase(%State{coinbase: coinbase}), do: coinbase
    def difficulty(%State{difficulty: difficulty}), do: difficulty
    def gasLimit(%State{gasLimit: gasLimit}), do: gasLimit
    def timestamp(%State{timestamp: timestamp}), do: timestamp
    def number(%State{number: number}), do: number

    def address(%State{tx: tx}), do: Transaction.to(tx)

    def account(%State{chain_state: st} = state),
      do: Chain.State.ensure_account(st, address(state))

    ###################################
    ##### AEVM ChainAPI functions #####
    ###################################
    require Record
    Record.defrecord(:call_result, result: nil, gas_spent: 0, type: :ok)

    @type call_result ::
            record(:call_result,
              result: binary() | atom(),
              gas_spent: non_neg_integer(),
              type: :exception | :revert | :ok
            )

    def set_store(store, %State{chain_state: st} = state) do
      # :io.format("set_store(~p) : ~p~n", [address(state), MerkleTree.to_list(store)])
      account = %{account(state) | storageRoot: store}
      %State{state | chain_state: Chain.State.set_account(st, address(state), account)}
    end

    def get_balance(address, %State{chain_state: st}) do
      Chain.State.ensure_account(st, :binary.part(address, 12, 20))
      |> Chain.Account.balance()
    end

    def get_extcode(address, %State{chain_state: st}) do
      Chain.State.ensure_account(st, :binary.part(address, 12, 20))
      |> Chain.Account.code()
    end

    def call_contract(_target, <<0::256>>, _gas, _value, _callData, _callStack, _origin, state) do
      {call_result(gas_spent: 0, type: :ok, result: <<0::256>>), state}
    end

    def call_contract(
          target,
          code,
          gas,
          value,
          callData,
          [caller | _callStack],
          _origin,
          %State{chain_state: st} = state
        ) do
      t = Chain.State.ensure_account(st, :binary.part(code, 12, 20))

      tx = %{
        state.tx
        | gasLimit: gas,
          value: value,
          data: callData,
          to: target |> Hash.to_address()
      }

      from = <<caller::160>>

      st1 =
        if value == 0 or from == tx.to do
          st
        else
          from_acc = Chain.State.account(st, from)
          to_acc = Chain.State.ensure_account(st, tx.to)

          st
          |> Chain.State.set_account(from, %{from_acc | balance: from_acc.balance - value})
          |> Chain.State.set_account(tx.to, %{to_acc | balance: to_acc.balance + value})
        end

      ret =
        Evm.eval_internal(
          evm(%{
            state
            | tx: tx,
              chain_state: st1,
              code: t.code,
              from: caller
          })
        )

      case ret do
        {:ok, evm} ->
          # :io.format("AFTER target = ~p gasLimit = ~p gas = ~p~n", [target, gas, Evm.gas(evm)])
          {call_result(result: Evm.out(evm), gas_spent: gas - Evm.gas(evm), type: :ok),
           %{
             state
             | chain_state: Evm.state(evm),
               selfdestructs: Evm.raw(evm).chain_state.selfdestructs
           }}

        {:error, reason, gasLeft} ->
          # :io.format("AFTER target = ~p gasLimit = ~p gas = ~p~n", [target, gas, gasLeft])
          {call_result(gas_spent: gas - gasLeft, type: :exception, result: reason), state}

        {:revert, reason, gasLeft} ->
          # :io.format("AFTER target = ~p gasLimit = ~p gas = ~p~n", [target, gas, gasLeft])
          {call_result(gas_spent: gas - gasLeft, type: :revert, result: reason), state}
      end
    end

    def create_account(
          value,
          code,
          evm = %{chain_state: %State{chain_state: st, tx: tx} = state, gas: gas}
        ) do
      address = State.address(state)
      account = Chain.State.account(st, address)

      to_address =
        Rlp.encode!([address, account.nonce])
        |> Hash.keccak_256()
        |> Hash.to_address()

      account = %{account | nonce: account.nonce + 1, balance: account.balance - value}
      to_account = %Chain.Account{nonce: 1, balance: value}

      st =
        st
        |> Chain.State.set_account(to_address, to_account)
        |> Chain.State.set_account(address, account)

      state = %{state | chain_state: st}

      tx = %{tx | value: value, data: nil, to: to_address, gasLimit: gas}

      if code != nil do
        case Evm.eval_internal(
               evm(%{
                 state
                 | tx: tx,
                   code: code,
                   from: State.address(state) |> :binary.decode_unsigned()
               })
             ) do
          {:ok, evm2} ->
            st = Evm.state(evm2)

            st =
              case Chain.State.account(st, to_address) do
                nil ->
                  st

                to_account ->
                  to_account = %{to_account | code: Evm.out(evm2)}
                  Chain.State.set_account(st, to_address, to_account)
              end

            evm = Evm.set_state(evm, st)
            {:binary.decode_unsigned(to_address), evm}

          {:error, _reason, gasLeft} ->
            {0, %{evm | gas: gasLeft}}

          {:revert, _reason, gasLeft} ->
            {0, %{evm | gas: gasLeft}}
        end
      else
        {0, evm}
      end
    end

    def gas_spent(call_result(gas_spent: gas_spent)), do: gas_spent
    def return_value(call_result(type: type, result: result)), do: {type, result}

    ##############################
    ##### EVM Init functions #####
    ##############################
    def gas(%State{tx: tx, internal: true}) do
      tx.gasLimit
    end

    def gas(%State{tx: tx}) do
      # Calculcation initial gas according to yellow paper 6.2
      gas = tx.gasLimit

      bytes = for <<byte::8 <- Transaction.payload(tx)>>, do: byte
      zeros = Enum.count(bytes, fn x -> x == 0 end)
      ones = Enum.count(bytes, fn x -> x > 0 end)

      gas = gas - zeros * Evm.gas_cost(:GTXDATAZERO)
      gas = gas - ones * Evm.gas_cost(:GTXDATANONZERO)

      gas =
        if Transaction.contract_creation?(tx) do
          gas - Evm.gas_cost(:GTXCREATE)
        else
          gas
        end

      gas - Evm.gas_cost(:GTRANSACTION)
    end

    def exec(%State{tx: tx, from: from, origin: origin} = state) do
      %{
        address: :binary.decode_unsigned(address(state)),
        caller: from,
        creator: from,
        data: Transaction.data(tx),
        gasPrice: Transaction.gasPrice(tx),
        value: Transaction.value(tx),
        gas: gas(state),
        code: code(state),
        mem: %{mem_size: 0},
        origin: origin,
        store: store(state),
        call_data_type: :undefined
      }
    end

    def env(%State{} = state) do
      %{
        abi_version: 1,
        chainState: %{state | internal: true},
        chainAPI: __MODULE__,
        currentCoinbase: coinbase(state),
        currentDifficulty: difficulty(state),
        currentGasLimit: gasLimit(state),
        currentTimestamp: timestamp(state),
        currentNumber: number(state),
        vm_version: 2
      }
    end

    def opts(%State{trace: trace}) do
      %{
        trace: trace,
        trace_fun: &Evm.log/2
      }
    end

    def evm(%State{} = state) do
      :aevm_eeevm_state.init(%{env: env(state), exec: exec(state), pre: %{}}, opts(state))
    end
  end

  def init() do
    w = Store.wallet()

    tx =
      Transaction.sign(%Transaction{gasLimit: 100_000, gasPrice: 0, value: 0}, Wallet.privkey!(w))

    from = :binary.decode_unsigned(Transaction.from(tx))

    state = %State{
      chain_state: %Chain.State{},
      tx: tx,
      from: from,
      origin: from,
      coinbase: Wallet.address!(w),
      difficulty: 5,
      gasLimit: 2_000_000,
      timestamp: DateTime.to_unix(DateTime.utc_now())
    }

    State.evm(state)
  end

  def init(
        tx = %Transaction{},
        state = %Chain.State{},
        block = %Chain.Block{},
        _store,
        code,
        trace? \\ false
      ) do
    from = :binary.decode_unsigned(Transaction.from(tx))

    state = %State{
      chain_state: state,
      code: code,
      trace: trace? or Diode.trace?(),
      tx: tx,
      from: from,
      origin: from,
      coinbase: Chain.Block.coinbase(block),
      difficulty: Chain.Block.difficulty(block),
      gasLimit: Chain.Block.gasLimit(block),
      timestamp: Chain.Block.timestamp(block),
      number: Chain.Block.number(block)
    }

    State.evm(state)
  end

  def log(format, args) do
    :io.format(format, args)
    # case Enum.at(args, 2) do
    #   nil -> :ok
    #   cmd -> :io.format("cmd: ~p~n", [cmd])
    # end
  end

  def eval(evm) do
    ret = eval_internal(evm)
    # :io.format("debug.trace2: ~p~n", [ret])

    with {:ok, evm2} <- ret do
      # Checking for selfdestruct
      state = evm2.chain_state

      st =
        Enum.reduce(state.selfdestructs, state.chain_state, fn {to, benefector}, st ->
          # Fetching balance and deleting the account
          balance = Chain.Account.balance(Chain.State.ensure_account(st, to))
          st = Chain.State.delete_account(st, to)

          # Sending balance to destination contract
          address = <<benefector::160>>

          if benefector == 0 or address == to do
            st
          else
            beneficiary = Chain.State.ensure_account(st, address)
            beneficiary = %{beneficiary | balance: beneficiary.balance + balance}
            Chain.State.set_account(st, address, beneficiary)
          end
        end)

      {:ok, %{evm2 | chain_state: %{state | chain_state: st}}}
    else
      _ -> ret
    end
  end

  def eval_internal(evm) do
    addr = State.address(evm.chain_state)
    to = Hash.integer(addr)

    case code(evm) do
      nil ->
        case PreCompiles.get(to) do
          nil -> {:ok, %{evm | out: ""}}
          fun -> eval_internal_precompile(evm, fun)
        end

      _ ->
        eval_internal_evm(evm)
    end
  end

  def eval_internal_precompile(evm, fun) do
    input = data(evm)
    gascost = fun.(:gas, input)

    if gascost > evm.gas do
      {:error, :out_of_gas, 0}
    else
      result = fun.(:run, input)
      result = binary_part(<<0::unsigned-size(256), result::binary>>, byte_size(result), 32)
      {:ok, %{evm | out: result, gas: evm.gas - gascost}}
    end
  end

  def eval_internal_evm(evm) do
    # bef = evm.gas
    ret = :aevm_eeevm.eval(evm)
    # ret = {_, %{trace: trace}} = :aevm_eeevm.eval(evm)
    # :io.format("debug.trace: ~p~n", [trace])

    with {:ok, evm2} <- ret do
      state = evm2.chain_state

      # Refunding
      maxRefund = div(State.gas(state) - evm2.gas, 2)
      refund = min(maxRefund, evm2.refund)
      evm2 = %{evm2 | gas: evm2.gas + refund}

      # Collecting selfdestruct
      evm2 =
        if evm2[:selfdestruct] != nil do
          selfdestructs = [{State.address(state), evm2[:selfdestruct]} | state.selfdestructs]
          %{evm2 | chain_state: %{state | selfdestructs: selfdestructs}}
        else
          evm2
        end

      # Correcting for codedeposit
      case evm2.out do
        nil ->
          {:ok, evm2}

        bin ->
          # :io.format("deducting ~p of ~p~n", [byte_size(bin) * gas_cost(:GCODEDEPOSIT), evm2.gas])
          deposit = byte_size(bin) * gas_cost(:GCODEDEPOSIT)

          if evm2.gas > deposit do
            {:ok, %{evm2 | gas: evm2.gas - deposit}}
          else
            {:error, :out_of_gas, 0}
          end
      end
    else
      _ -> ret
    end
  end

  def raw(evm) do
    evm
  end

  def gas({:error, _reason, _gas}) do
    -1
  end

  def gas(evm) do
    evm.gas
  end

  def code(evm) do
    evm.code
  end

  def logs(evm) do
    evm.logs
  end

  def out(evm) do
    evm.out
  end

  def data(evm) do
    evm.data
  end

  def return_data(evm) do
    evm.return_data
  end

  def storage(evm) do
    evm.storage
  end

  def trace(evm) do
    evm.trace
  end

  def state(evm) do
    evm.chain_state.chain_state
  end

  def set_state(evm, state) do
    %{evm | chain_state: %{evm.chain_state | chain_state: state}}
  end

  def gas_cost(atom) do
    :aec_governance.vm_gas_table()[atom]
  end
end
