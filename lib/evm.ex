# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
defmodule Evm do
  @moduledoc """
  EVM Interface using an extern C application based on EVMC (currently Aleth)
  """
  alias Chain.{Transaction, Account}

  defstruct port: nil,
            chain_state: nil,
            refund: nil,
            code: nil,
            gas: nil,
            selfdestruct: nil,
            out: nil,
            return_data: nil,
            data: nil,
            logs: [],
            trace: nil,
            msg: :evmc_success,
            create_address: 0

  @type t :: %Evm{}

  defmodule State do
    defstruct chain_state: nil,
              static: false,
              from: nil,
              origin: nil,
              tx: nil,
              code: "",
              trace: false,
              coinbase: nil,
              difficulty: 0,
              gas_limit: 0,
              timestamp: 0,
              number: 0,
              internal: false,
              selfdestructs: []

    @type t :: %Evm.State{}

    @spec store(Evm.State.t()) :: MerkleTree.merkle()
    def store(%State{chain_state: st} = state) do
      Chain.State.ensure_account(st, address(state))
      |> Account.tree()
    end

    def code(%State{code: code}), do: code
    def coinbase(%State{coinbase: coinbase}), do: coinbase
    def difficulty(%State{difficulty: difficulty}), do: difficulty
    def gas_limit(%State{gas_limit: gas_limit}), do: gas_limit
    def gas_price(%State{tx: tx}), do: Transaction.gas_price(tx)
    def timestamp(%State{timestamp: timestamp}), do: timestamp
    def number(%State{number: number}), do: number

    def address(%State{tx: tx}), do: Transaction.to(tx)

    def account(%State{chain_state: st} = state),
      do: Chain.State.ensure_account(st, address(state))

    def call_contract(target, kind, gas, value, call_data, caller, state) do
      target = <<target::unsigned-size(160)>>
      from = <<caller::unsigned-size(160)>>

      case kind do
        :evmc_create ->
          do_create(value, call_data, gas, state)

        :evmc_callcode ->
          do_call_contract(from, target, gas, value, call_data, from, state)

        :evmc_call ->
          do_call_contract(target, target, gas, value, call_data, from, state)

        _other ->
          do_call_contract(target, target, gas, value, call_data, from, state)
      end
    end

    defp do_call_contract(
           target,
           code,
           gas,
           value,
           call_data,
           from,
           %State{chain_state: st} = state
         ) do
      code = Chain.State.ensure_account(st, code).code

      tx = %{
        state.tx
        | gasLimit: gas,
          value: value,
          data: call_data,
          to: target
      }

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

      evm =
        evm(%{
          state
          | tx: tx,
            chain_state: st1,
            code: code,
            internal: true,
            from: from |> :binary.decode_unsigned()
        })

      Evm.eval_internal(evm)
    end

    defp do_create(
           value,
           code,
           gas,
           %State{chain_state: st, tx: tx} = state
         ) do
      address = State.address(state)
      account = Chain.State.account(st, address)

      to_address =
        Rlp.encode!([address, account.nonce])
        |> Hash.keccak_256()
        |> Hash.to_address()

      account = %{account | nonce: account.nonce + 1, balance: account.balance - value}
      to_account = Account.new(nonce: 1, balance: value)

      st =
        st
        |> Chain.State.set_account(to_address, to_account)
        |> Chain.State.set_account(address, account)

      state = %{state | chain_state: st}
      tx = %{tx | value: value, data: nil, to: to_address, gasLimit: gas}

      evm =
        evm(%{
          state
          | tx: tx,
            code: code,
            from: State.address(state) |> :binary.decode_unsigned()
        })

      if code != nil do
        case Evm.eval_internal(evm) do
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

            evm2 = Evm.set_state(evm2, st)
            {:ok, %{evm2 | create_address: Hash.integer(to_address), out: ""}}

          {error, evm2} ->
            {error, evm2}
        end
      else
        {:ok, evm}
      end
    end

    ##############################
    ##### EVM Init functions #####
    ##############################
    def gas(%State{tx: tx, internal: true}) do
      Transaction.gas_limit(tx)
    end

    def gas(%State{tx: tx}) do
      # Calculcation initial gas according to yellow paper 6.2
      gas = Transaction.gas_limit(tx)

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

    def evm(%State{} = state) do
      %Evm{chain_state: state, code: code(state), gas: gas(state)}
    end
  end

  def init() do
    w = Diode.miner()

    tx =
      Transaction.sign(
        %Transaction{gasLimit: 100_000, gasPrice: 0, value: 0},
        Wallet.privkey!(w)
      )

    from = :binary.decode_unsigned(Transaction.from(tx))

    state = %State{
      chain_state: Chain.State.new(),
      tx: tx,
      from: from,
      origin: from,
      coinbase: Wallet.address!(w) |> :binary.decode_unsigned(),
      difficulty: 5,
      gas_limit: 2_000_000,
      timestamp: DateTime.to_unix(DateTime.utc_now())
    }

    State.evm(state)
  end

  def init(
        tx = %Transaction{},
        state = %Chain.State{},
        block = %Chain.Block{},
        code,
        opts \\ []
      ) do
    from = :binary.decode_unsigned(Transaction.from(tx))

    state = %State{
      chain_state: state,
      code: code,
      trace: Keyword.get(opts, :trace, false) or Diode.trace?(),
      static: Keyword.get(opts, :static, false),
      tx: tx,
      from: from,
      origin: from,
      coinbase: Chain.Block.coinbase(block),
      difficulty: Chain.Block.difficulty(block),
      gas_limit: Chain.Block.gas_limit(block),
      timestamp: Chain.Block.timestamp(block),
      number: Chain.Block.number(block)
    }

    State.evm(state)
  end

  def eval(evm) do
    Stats.tc(:eval_time, fn -> eval_timed(evm) end)
  end

  defp eval_timed(evm) do
    ret = eval_internal(evm)

    with {:ok, evm2} <- ret do
      # Checking for selfdestruct
      state = evm2.chain_state

      st =
        Enum.reduce(state.selfdestructs, state.chain_state, fn {to, benefector}, st ->
          # Fetching balance and deleting the account
          balance = Account.balance(Chain.State.ensure_account(st, to))
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

    if code(evm) == "" or code(evm) == nil do
      case PreCompiles.get(to) do
        nil -> {:ok, %{evm | out: ""}}
        fun -> eval_internal_precompile(evm, fun)
      end
    else
      eval_internal_evm(evm)
    end
  end

  def eval_internal_precompile(evm, fun) do
    input = input(evm)
    gascost = fun.(:gas, input)

    if gascost > evm.gas do
      {:evmc_out_of_gas, %{evm | gas: 0, msg: :evmc_out_of_gas}}
    else
      result = fun.(:run, input)
      result = binary_part(<<0::unsigned-size(256), result::binary>>, byte_size(result), 32)
      {:ok, %{evm | out: result, gas: evm.gas - gascost}}
    end
  end

  def eval_internal_evm(evm) do
    ret = do_eval(evm)

    with {:ok, evm2} <- ret do
      state = evm2.chain_state

      # Refunding
      maxRefund = div(State.gas(state) - evm2.gas, 2)
      refund = min(maxRefund, evm2.refund)
      evm2 = %{evm2 | gas: evm2.gas + refund}

      # Collecting selfdestruct
      evm2 =
        if evm2.selfdestruct != nil do
          selfdestructs = [{State.address(state), evm2.selfdestruct} | state.selfdestructs]
          %{evm2 | chain_state: %{state | selfdestructs: selfdestructs}}
        else
          evm2
        end

      # Correcting for codedeposit
      case evm2.out do
        nil ->
          {:ok, evm2}

        bin ->
          deposit = byte_size(bin) * gas_cost(:GCODEDEPOSIT)

          if evm2.gas > deposit do
            {:ok, %{evm2 | gas: evm2.gas - deposit}}
          else
            {:evmc_out_of_gas, %{evm2 | gas: 0}}
          end
      end
    else
      _ -> ret
    end
  end

  defp do_eval(evm) do
    Stats.tc(:evm, fn -> do_eval2(evm) end)
  end

  defp release_port(port) do
    rest = Process.get(:evm_port, [])
    Process.put(:evm_port, [port | rest])
  end

  defp new_port() do
    case Process.get(:evm_port, []) do
      [] ->
        Port.open({:spawn_executable, "./evm/evm"}, [:binary, {:packet, 4}])

      [port | rest] ->
        Process.put(:evm_port, rest)
        port
    end
  end

  defp do_eval2(evm = %{port: nil, chain_state: state}) do
    port = new_port()

    init_context = <<
      "c",
      State.gas_price(state)::unsigned-little-size(256),
      state.origin::unsigned-size(160),
      State.coinbase(state)::unsigned-size(160),
      State.number(state)::unsigned-little-size(64),
      State.timestamp(state)::unsigned-little-size(64),
      State.gas_limit(state)::unsigned-little-size(64),
      State.difficulty(state)::unsigned-little-size(256),
      # chain_id
      0::unsigned-size(256)
    >>

    Stats.tc(:evm_init_release, fn ->
      true = Port.command(port, init_context)
      evm = %{evm | port: port}
      ret = do_eval2(evm)
      release_port(port)
      ret
    end)
  end

  defp do_eval2(evm) do
    to = :binary.decode_unsigned(State.address(evm.chain_state))
    cache_account(state(evm), evm.port, to)
    tx = evm.chain_state.tx

    value = Transaction.value(tx)
    input = input(evm)
    input_len = byte_size(input)

    code = code(evm)
    code_len = byte_size(code)

    message =
      Stats.tc(:prep_message, fn ->
        [
          <<"r", evm.chain_state.from::unsigned-size(160), to::unsigned-size(160),
            value::unsigned-size(256), input_len::signed-little-size(64)>>,
          input,
          <<
            gas(evm)::unsigned-little-size(64),
            # depth
            0::unsigned-little-size(32),
            code_len::signed-little-size(64)
          >>,
          code
        ]
      end)

    Stats.tc(:evm_loop, fn ->
      Port.command(evm.port, message)
      loop({:cont, evm})
    end)
  end

  defp cache_account(state, port, address) do
    values =
      Chain.State.ensure_account(state, address)
      |> Chain.Account.tree()
      |> MerkleTree.to_list()
      |> Enum.map(fn {k, v} -> [k, v] end)

    cache = [
      <<"p", length(values)::unsigned-little-size(32), address::unsigned-size(160)>>,
      values
    ]

    true = Port.command(port, cache)
  end

  defp loop({:cont, evm}) do
    receive do
      {_port, {:data, data}} ->
        loop(Stats.tc(:process_data, fn -> process_data(data, evm) end))

      {'EXIT', _port, _reason} ->
        throw({:evm_crash, evm, 0})
    after
      5000 ->
        throw({:evm_timeout, evm, 0})
    end
  end

  defp loop(other) do
    other
  end

  # finished code execution
  defp process_data(
         <<"ok", gas_left::signed-little-size(64), ret_code::signed-little-size(64),
           len::unsigned-little-size(64), rest::binary-size(len)>>,
         evm
       ) do
    status = status_code(ret_code)
    evm = %{evm | out: rest, gas: gas_left, msg: status}

    case status do
      :evmc_success -> {:ok, evm}
      other -> {other, evm}
    end
  end

  # get_storage(addr, key)
  defp process_data(
         <<"gs", addr::binary-size(20), key::binary-size(32)>>,
         evm
       ) do
    value =
      Chain.State.ensure_account(state(evm), addr)
      |> Chain.Account.tree()
      |> MerkleTree.get(key)

    if value == nil do
      # IO.puts("gs #{Base16.encode(key)} = nil")
      Port.command(evm.port, <<0::unsigned-size(256)>>)
    else
      # IO.puts("gs #{Base16.encode(key)} = #{Base16.encode(value)}")
      Port.command(evm.port, value)
    end

    {:cont, evm}
  end

  # storage_update(addr, [{key, value}])
  # static calls don't change the state
  defp process_data(<<"su", _rest::binary>>, %{chain_state: %{static: true}} = evm) do
    {:cont, evm}
  end

  defp process_data(<<"su", rest::binary>>, evm) do
    updates = parse_map(rest, %{})

    state =
      Enum.reduce(updates, state(evm), fn {addr, kvs}, state ->
        acc = Chain.State.ensure_account(state, addr)
        root = MerkleTree.insert_items(Account.tree(acc), Map.to_list(kvs))
        acc = Chain.Account.put_tree(acc, root)
        Chain.State.set_account(state, addr, acc)
      end)

    {:cont, set_state(evm, state)}
  end

  # account_exists?()
  defp process_data(<<"ae", addr::binary-size(20)>>, evm) do
    state = state(evm)

    ret =
      case Chain.State.account(state, addr) do
        nil -> 0
        %Account{} -> 1
      end

    true = Port.command(evm.port, <<ret::unsigned-little-size(64)>>)
    {:cont, evm}
  end

  # get_balance(addr)
  defp process_data(<<"gb", addr::binary-size(20)>>, evm) do
    value =
      Chain.State.ensure_account(state(evm), addr)
      |> Account.balance()

    true = Port.command(evm.port, <<value::unsigned-size(256)>>)
    {:cont, evm}
  end

  # get_code_size(addr)
  defp process_data(<<"gc", addr::binary-size(20)>>, evm) do
    size =
      Chain.State.ensure_account(state(evm), addr)
      |> Account.code()
      |> byte_size()

    true = Port.command(evm.port, <<size::unsigned-little-size(64)>>)
    {:cont, evm}
  end

  # get_code_hash(addr)
  defp process_data(<<"gd", addr::binary-size(20)>>, evm) do
    hash =
      Chain.State.ensure_account(state(evm), addr)
      |> Account.codehash()

    true = Port.command(evm.port, <<hash::binary-size(32)>>)
    {:cont, evm}
  end

  # copy_code(addr)
  defp process_data(
         <<"cc", addr::binary-size(20), offset::unsigned-little-size(64),
           size::unsigned-little-size(64)>>,
         evm
       ) do
    code =
      Chain.State.ensure_account(state(evm), addr)
      |> Account.code()

    length = min(size, byte_size(code) - offset)
    code = binary_part(code, offset, length)

    true = Port.command(evm.port, <<length::unsigned-little-size(64), code::binary-size(length)>>)
    {:cont, evm}
  end

  # selfdestruct(addr, benefactor)
  defp process_data(
         <<"sd", _addr::binary-size(20), ben::binary-size(20)>>,
         evm
       ) do
    {:cont, %{evm | selfdestruct: ben}}
  end

  # get_block_hash(number)
  defp process_data(<<"gh", number::signed-little-size(64)>>, evm) do
    blockheight = State.number(evm.chain_state)
    minimum = max(0, blockheight - Chain.blockhash_limit(blockheight))
    maximum = blockheight

    hash =
      if number < minimum or number > maximum do
        <<0::256>>
      else
        Chain.block(number) |> Chain.Block.hash()
      end

    true = Port.command(evm.port, <<hash::binary-size(32)>>)
    {:cont, evm}
  end

  # call(...)
  defp process_data(
         <<"ca", kind::signed-little-size(64), sender::unsigned-size(160),
           destination::unsigned-size(160), value::unsigned-size(256),
           len::unsigned-little-size(64), input::binary-size(len),
           gas::unsigned-little-size(64)>>,
         evm
       ) do
    kind =
      case kind do
        0 -> :evmc_call
        1 -> :evmc_delegatecall
        2 -> :evmc_callcode
        3 -> :evmc_create
        4 -> :evmc_create2
      end

    {code, evm2} =
      State.call_contract(destination, kind, gas, value, input, sender, evm.chain_state)

    state =
      if code == :ok do
        %{
          evm.chain_state
          | chain_state: Evm.state(evm2),
            selfdestructs: evm2.chain_state.selfdestructs
        }
      else
        evm.chain_state
      end

    code = status_atom(evm2.msg)

    message = <<
      Evm.gas(evm2)::unsigned-little-size(64),
      code::signed-little-size(64),
      byte_size(Evm.out(evm2))::unsigned-little-size(64),
      Evm.out(evm2)::binary,
      Evm.create_address(evm2)::unsigned-size(160)
    >>

    true = Port.command(evm.port, message)
    {:cont, %{evm | chain_state: state}}
  end

  # emit_log(number)
  defp process_data(
         <<"lo", addr::binary-size(20), size::unsigned-little-size(64), data::binary-size(size),
           count::unsigned-little-size(64), topics::binary>>,
         evm
       ) do
    topics = for n <- 1..count, do: binary_part(topics, (n - 1) * 32, 32)
    logs = evm.logs ++ [{addr, topics, data}]
    {:cont, %{evm | logs: logs}}
  end

  defp process_data(other, evm) do
    IO.puts("EVM.process_data what?: #{inspect(other)}")
    {:cont, evm}
  end

  defp status_code(0), do: :evmc_success
  defp status_code(1), do: :evmc_failure
  defp status_code(2), do: :evmc_revert
  defp status_code(3), do: :evmc_out_of_gas
  defp status_code(4), do: :evmc_invalid_instruction
  defp status_code(5), do: :evmc_undefined_instruction
  defp status_code(6), do: :evmc_stack_overflow
  defp status_code(7), do: :evmc_stack_underflow
  defp status_code(8), do: :evmc_bad_jump_destination
  defp status_code(9), do: :evmc_invalid_memory_access
  defp status_code(10), do: :evmc_call_depth_exceeded
  defp status_code(11), do: :evmc_static_mode_violation
  defp status_code(12), do: :evmc_precompile_failure
  defp status_code(13), do: :evmc_validation_failure
  defp status_code(14), do: :evmc_argument_out_of_range
  defp status_code(15), do: :evmc_wasm_unreachable_instruction
  defp status_code(16), do: :evmc_wasm_trap
  defp status_code(-1), do: :evmc_internal_error
  defp status_code(-2), do: :evmc_rejected
  defp status_code(-3), do: :evmc_out_of_memory
  defp status_atom(:evmc_success), do: 0
  defp status_atom(:evmc_failure), do: 1
  defp status_atom(:evmc_revert), do: 2
  defp status_atom(:evmc_out_of_gas), do: 3
  defp status_atom(:evmc_invalid_instruction), do: 4
  defp status_atom(:evmc_undefined_instruction), do: 5
  defp status_atom(:evmc_stack_overflow), do: 6
  defp status_atom(:evmc_stack_underflow), do: 7
  defp status_atom(:evmc_bad_jump_destination), do: 8
  defp status_atom(:evmc_invalid_memory_access), do: 9
  defp status_atom(:evmc_call_depth_exceeded), do: 10
  defp status_atom(:evmc_static_mode_violation), do: 11
  defp status_atom(:evmc_precompile_failure), do: 12
  defp status_atom(:evmc_validation_failure), do: 13
  defp status_atom(:evmc_argument_out_of_range), do: 14
  defp status_atom(:evmc_wasm_unreachable_instruction), do: 15
  defp status_atom(:evmc_wasm_trap), do: 16
  defp status_atom(:evmc_internal_error), do: -1
  defp status_atom(:evmc_rejected), do: -2
  defp status_atom(:evmc_out_of_memory), do: -3

  def gas(evm) do
    evm.gas
  end

  defp code(evm) do
    evm.code
  end

  def logs(evm) do
    evm.logs
  end

  def out(evm) do
    evm.out
  end

  def create_address(evm) do
    evm.create_address
  end

  def return_data(evm) do
    evm.return_data
  end

  def input(evm) do
    Transaction.payload(evm.chain_state.tx)
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
    case atom do
      :GZERO -> 0
      :GBASE -> 2
      :GVERYLOW -> 3
      :GLOW -> 5
      :GMID -> 8
      :GHIGH -> 10
      :GEXTCODESIZE -> 700
      :GEXTCODECOPY -> 700
      :GBALANCE -> 400
      :GSLOAD -> 200
      :GJUMPDEST -> 1
      :GSSET -> 20000
      :GSRESET -> 5000
      :RSCLEAR -> 15000
      :RSELFDESTRUCT -> 24000
      :GSELFDESTRUCT -> 5000
      :GCREATE -> 32000
      :GCODEDEPOSIT -> 200
      :GCALL -> 700
      :GCALLVALUE -> 9000
      :GCALLSTIPEND -> 2300
      :GNEWACCOUNT -> 25000
      :GEXP -> 10
      :GEXPBYTE -> 50
      :GMEMORY -> 3
      :GTXCREATE -> 32000
      :GTXDATAZERO -> 4
      :GTXDATANONZERO -> 68
      :GTRANSACTION -> 21000
      :GLOG -> 375
      :GLOGDATA -> 8
      :GLOGTOPIC -> 375
      :GSHA3 -> 30
      :GSHA3WORD -> 6
      :GCOPY -> 3
      :GBLOCKHASH -> 20
    end
  end

  defp parse_map(
         <<addr::binary-size(20), key::binary-size(32), value::binary-size(32), rest::binary>>,
         map
       ) do
    parse_map(
      rest,
      Map.update(map, addr, %{key => value}, fn acc -> Map.put(acc, key, value) end)
    )
  end

  defp parse_map("", map) do
    map
  end
end
