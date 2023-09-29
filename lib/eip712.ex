defmodule EIP712 do
  defstruct [:primary_type, :types, :message]

  def encode(domain_separator, primary_type, type_data, message) do
    Hash.keccak_256(
      "\x19\x01" <> domain_separator <> hash_struct(primary_type, type_data, message)
    )
  end

  # Special case for a flat EIP712 (no nested user types)
  def encode(domain_separator, primary_type, message) do
    {types, values} = split_fields(message)
    encode(domain_separator, primary_type, %{primary_type => types}, values)
  end

  def encode_type(primary_type, type_data) do
    prefix = encode_single_type(primary_type, Map.get(type_data, primary_type))

    types =
      Enum.map(type_data[primary_type], fn
        {_name, type} -> type
        {_name, type, _value} -> type
      end)
      |> Enum.uniq()

    postfix =
      Enum.filter(type_data, fn
        {name, _} -> name != primary_type and name in types
      end)
      |> Enum.map(fn {name, fields} -> encode_single_type(name, fields) end)
      |> Enum.sort()
      |> Enum.join()

    prefix <> postfix
  end

  def encode_single_type(type, fields) do
    names =
      Enum.map(fields, fn
        {name, type} -> "#{type} #{name}"
        {name, type, _value} -> "#{type} #{name}"
      end)

    type <> "(" <> Enum.join(names, ",") <> ")"
  end

  def type_hash(primary_type, type_data) when is_map(type_data) do
    encode_type(primary_type, type_data) |> Hash.keccak_256()
  end

  @spec hash_struct(binary(), [{String.t(), String.t(), any()}]) :: binary()
  def hash_struct(primary_type, type_data) do
    {types, values} = split_fields(type_data)
    hash_struct(primary_type, %{primary_type => types}, values)
  end

  def hash_struct(primary_type, type_data, message) do
    encode_data =
      Enum.map(type_data[primary_type], fn {name, type} when is_binary(type) ->
        value = Map.get(message, name)

        cond do
          type == "bytes" or type == "string" ->
            ABI.encode("bytes32", Hash.keccak_256(value))

          Map.has_key?(type_data, type) ->
            hash_struct(type, type_data, value)

          true ->
            ABI.encode(type, value)
        end
      end)
      |> Enum.join()

    Hash.keccak_256(type_hash(primary_type, type_data) <> encode_data)
  end

  def hash_domain_separator(name, version, chain_id, verifying_contract)
      when is_binary(name) and is_binary(version) and is_integer(chain_id) and
             is_binary(verifying_contract) do
    hash_struct("EIP712Domain", [
      {"name", "string", name},
      {"version", "string", version},
      {"chainId", "uint256", chain_id},
      {"verifyingContract", "address", verifying_contract}
    ])
  end

  defp split_fields(fields) do
    {types, values} =
      Enum.map(fields, fn {name, type, value} ->
        {{name, type}, {name, value}}
      end)
      |> Enum.unzip()

    {types, Map.new(values)}
  end
end
