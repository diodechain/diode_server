# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
Benchee.run(
  %{
    "increment" => &Bench.increment/1
  },
  inputs: %{
    "fib(11)" => Bench.create_contract(1, 11),
    "fib(23)" => Bench.create_contract(1, 23),
    "fib(27)" => Bench.create_contract(1, 27)
  },
  time: 20
)
