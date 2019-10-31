# MIX_ENV=benchmark mix run benchmark.exs
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
