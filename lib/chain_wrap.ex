defmodule ChainWrap do
  def epoch() do
    0
  end

  def peak() do
    1000
  end

  def genesis_hash() do
    # https://moonbase.moonscan.io/block/0
    0x33638DDE636F9264B6472B9D976D58E757FE88BADAC53F204F3F530ECC5AACFA
  end

  def light_node?() do
    true
  end
end
