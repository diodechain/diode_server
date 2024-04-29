# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
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
