# This file contains your private keys for the miner and
# your additional wallets for use of the RPC interface.
#
# Copy this file to config/diode.exs to replace the generated miner key
#      with your own.
use Mix.Config

config Diode,
  miner:
    :binary.decode_unsigned(0x1111111111111111111111111111111111111111111111111111111111111111),
  wallets: [
    :binary.decode_unsigned(0x2222222222222222222222222222222222222222222222222222222222222222)
  ]
