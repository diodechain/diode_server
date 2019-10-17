defmodule Chain.Transaction do
  alias Chain.transaction_receipt

  defstruct nonce: 1,
            gas_price: 0,
            gas_limit: 0,
            to: nil,
            value: 0,
            signature: nil,
            init: nil,
            data: nil

  def nonce(%Chain.Transaction{nonce: nonce}), do: nonce
  def data(%Chain.Transaction{data: nil}), do: ""
  def data(%Chain.Transaction{data: data}), do: data
  def gas_price(%Chain.Transaction{gas_price: gas_price}), do: gas_price
  def gas_limit(%Chain.Transaction{gas_limit: gas_limit}), do: gas_limit
  def value(%Chain.Transaction{value: val}), do: val
  def signature(%Chain.Transaction{signature: sig}), do: sig
  def payload(%Chain.Transaction{to: nil, init: nil}), do: ""
  def payload(%Chain.Transaction{to: nil, init: init}), do: init
  def payload(%Chain.Transaction{data: nil}), do: ""
  def payload(%Chain.Transaction{data: data}), do: data
  def to(%Chain.Transaction{to: nil} = tx), do: new_contract_address(tx)
  def to(%Chain.Transaction{to: to}), do: to

  @spec from_rlp(binary()) :: Chain.Transaction.t()
  def from_rlp(bin) do
    [nonce, gas_price, gas_limit, to, value, init, rec, r, s] = Rlp.decode!(bin)

    to = Rlp.bin2addr(to)

    %Chain.Transaction{
      nonce: Rlp.bin2num(nonce),
      gas_price: Rlp.bin2num(gas_price),
      gas_limit: Rlp.bin2num(gas_limit),
      to: to,
      value: Rlp.bin2num(value),
      init: if(to == nil, do: init, else: nil),
      data: if(to != nil, do: init, else: nil),
      signature: Secp256k1.rlp_to_bitcoin(rec, r, s)
    }
  end

  @spec valid?(Chain.Transaction.t()) :: boolean()
  def valid?(tx) do
    validate(tx) == true
  end

  @spec type(Chain.Transaction.t()) :: :call | :create
  def type(tx) do
    if contract_creation?(tx) do
      :create
    else
      :call
    end
  end

  @spec validate(Chain.Transaction.t()) :: true | {non_neg_integer(), any()}
  def validate(tx) do
    with {1, %Chain.Transaction{}} <- {1, tx},
         {2, 65} <- {2, byte_size(signature(tx))},
         {4, true} <- {4, value(tx) >= 0},
         {5, true} <- {5, gas_price(tx) >= 0},
         {6, true} <- {6, gas_limit(tx) >= 0},
         {7, true} <- {7, byte_size(payload(tx)) >= 0} do
      true
    else
      {nr, error} -> {nr, error}
    end
  end

  @spec contract_creation?(Chain.Transaction.t()) :: boolean()
  def contract_creation?(%Chain.Transaction{to: to}) do
    to == nil
  end

  @spec new_contract_address(Chain.Transaction.t()) :: binary()
  def new_contract_address(%Chain.Transaction{to: to}) when to != nil do
    nil
  end

  def new_contract_address(%Chain.Transaction{nonce: nonce} = tx) do
    address = Wallet.address!(origin(tx))

    Rlp.encode!([address, nonce])
    |> Hash.keccak_256()
    |> Hash.to_address()
  end

  @spec to_rlp(Chain.Transaction.t()) :: [...]
  def to_rlp(tx) do
    [tx.nonce, tx.gas_price, tx.gas_limit, tx.to, tx.value, payload(tx)] ++
      Secp256k1.bitcoin_to_rlp(tx.signature)
  end

  @spec from(Chain.Transaction.t()) :: <<_::160>>
  def from(tx) do
    Wallet.address!(origin(tx))
  end

  @spec recover(Chain.Transaction.t()) :: binary()
  def recover(tx) do
    Secp256k1.recover!(signature(tx), to_message(tx), :kec)
  end

  @spec origin(Chain.Transaction.t()) :: Wallet.t()
  def origin(tx) do
    recover(tx) |> Wallet.from_pubkey()
  end

  @spec sign(Chain.Transaction.t(), <<_::256>>) :: Chain.Transaction.t()
  def sign(tx = %Chain.Transaction{}, priv) do
    %{tx | signature: Secp256k1.sign(priv, to_message(tx), :kec)}
  end

  @spec hash(Chain.Transaction.t()) :: binary()
  def hash(tx) do
    to_rlp(tx) |> Rlp.encode!() |> Diode.hash()
  end

  @spec to_message(Chain.Transaction.t()) :: binary()
  def to_message(tx) do
    [tx.nonce, tx.gas_price, tx.gas_limit, tx.to, tx.value, payload(tx)]
    |> Rlp.encode!()
  end

  @spec apply(Chain.Transaction.t(), Chain.Block.t(), Chain.State.t(), false | true) ::
          {:error, atom()} | {:ok, Chain.State.t(), Chain.Receipt.t()}
  def apply(
        tx = %Chain.Transaction{nonce: nonce},
        env = %Chain.Block{},
        state = %Chain.State{},
        trace? \\ false
      ) do
    # :io.format("tx origin: ~p~n", [origin(tx)])

    from = from(tx)
    # IO.puts("Nonce: #{nonce} => #{Chain.State.account(state, from).nonce}")

    # Note: Even a non-existing account can send transaction, as long as value and gas_price are 0
    # :io.format("Trying nonce ~p (should be ~p) on account ~p~n", [nonce, Chain.State.ensure_account(state, from).nonce, from])
    # :io.format("~p~n", [:erlang.process_info(self(), :current_stacktrace)])
    case Chain.State.ensure_account(state, from) do
      from_acc = %Chain.Account{nonce: ^nonce} ->
        fee = gas_limit(tx) * gas_price(tx)

        # Deducting fee and value from source account
        from_acc = %{from_acc | nonce: nonce + 1, balance: from_acc.balance - tx.value - fee}

        if from_acc.balance < 0 do
          {:error, :not_enough_balance}
        else
          do_apply(tx, env, state, from, from_acc, trace?)
        end

      %Chain.Account{nonce: low} when low < nonce ->
        {:error, :nonce_too_high}

      _acc ->
        {:error, :wrong_nonce}
    end
  end

  defp do_apply(tx, env, state, from, from_acc, trace?) do
    # Creating / finding destination account
    {acc, code} =
      if contract_creation?(tx) do
        acc = %Chain.Account{nonce: 1}
        {acc, payload(tx)}
      else
        acc = Chain.State.ensure_account(state, to(tx))
        {acc, Chain.Account.code(acc)}
      end

    # Adding tx.value to it's balance
    acc = %{acc | balance: acc.balance + tx.value}

    new_state =
      state
      |> Chain.State.set_account(from, from_acc)
      |> Chain.State.set_account(to(tx), acc)

    evm = Evm.init(tx, new_state, env, acc.storage_root, code, trace?)

    case Evm.eval(evm) do
      {:ok, evm} ->
        new_state = Evm.state(evm)

        from_acc = Chain.State.account(new_state, from)
        from_acc = %{from_acc | balance: from_acc.balance + Evm.gas(evm) * gas_price(tx)}
        new_state = Chain.State.set_account(new_state, from, from_acc)

        # The destination might be selfdestructed
        new_state =
          case Chain.State.account(new_state, to(tx)) do
            nil ->
              new_state

            acc ->
              acc = if contract_creation?(tx), do: %{acc | code: Evm.out(evm)}, else: acc
              Chain.State.set_account(new_state, to(tx), acc)
          end

        # :io.format("evm: ~240p~n", [evm])
        {:ok, new_state,
         %transaction_receipt{
           evmout: Evm.out(evm),
           return_data: Evm.return_data(evm),
           data: Evm.data(evm),
           logs: Evm.logs(evm),
           trace: Evm.trace(evm),
           gas_used: gas_limit(tx) - Evm.gas(evm),
           msg: :ok
         }}

      {:error, msg, gas_left} ->
        # Only applying the full fee (restoring the tx.value)
        state =
          Chain.State.set_account(state, from, %{
            from_acc
            | balance: from_acc.balance + tx.value
          })

        {:ok, state, %transaction_receipt{msg: msg, gas_used: gas_limit(tx) - gas_left}}

      {:revert, message, gas_left} ->
        # Only applying the delta fee (see new_state vs. state)
        gas_used = gas_limit(tx) - gas_left

        state =
          Chain.State.set_account(state, from, %{
            from_acc
            | balance: from_acc.balance + gas_left * gas_price(tx) + tx.value
          })

        {:ok, state, %transaction_receipt{msg: :revert, gas_used: gas_used, evmout: message}}
    end
  end
end
