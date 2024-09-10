:persistent_term.put(:env, :prod)
# System.put_env("DATA_DIR", "data_prod")
{:ok, _db} = Model.Sql.start_database(Db.Default, Db.Default)
{:ok, _} = Application.ensure_all_started(:mutable_map)

block_number = 7554001


block = Model.ChainSql.block(block_number)
IO.inspect(Model.ChainSql.is_jumpblock(block), label: "is_jumpblock")
state = Model.ChainSql.state(Chain.Block.hash(block))

IO.inspect(Map.has_key?(state, :store), label: "has store")

IO.inspect(Chain.Block.state_consistent?(block))
