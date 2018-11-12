defmodule Hash do
  @spec integer(binary()) :: non_neg_integer()
  def integer(hash) do
    :binary.decode_unsigned(hash)
  end

  def to_address(hash = <<_::256>>) do
    binary_part(hash, 12, 20)
  end
end
