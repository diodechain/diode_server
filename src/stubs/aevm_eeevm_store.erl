-module(aevm_eeevm_store).
-export([init/2, load/2, store/3, to_binary/1]).

%%====================================================================
%% API
%%====================================================================

-spec init(aect_contracts:store(), aevm_eeevm_state:state()) -> aevm_eeevm_state:state().
init(Store, State) -> 
    State#{ storage => Store }.


-spec to_binary(aevm_eeevm_state:state()) -> aect_contracts:store().
to_binary(#{ storage := Storage }) ->
    Storage.

-spec load(integer(), aevm_eeevm_state:state()) -> integer().
load(Address, State) ->
    Store = aevm_eeevm_state:storage(State),
    case 'Elixir.MerkleTree':get(Store, Address) of
        << Value:256/unsigned-integer >> -> Value;
        nil -> 0
    end.

-spec store(integer(), integer(), aevm_eeevm_state:state()) -> aevm_eeevm_state:state().
store(Address, Value, State) when is_integer(Value) ->
    Store = aevm_eeevm_state:storage(State),
    %% Make sure value fits in 256 bits.
    Value256 = << Value:256/unsigned-integer >>,
    Store1 = case Value of
        0 -> 'Elixir.MerkleTree':delete(Store, Address);
        _ -> 'Elixir.MerkleTree':insert(Store, Address, Value256)
    end,
    aevm_eeevm_state:set_storage(Store1, State).