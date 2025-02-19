
Logger.configure(level: :info)
data = File.read!("profile_273315140.cprof")

IO.puts("zlib.deflate")
for _i <- 1..3 do
  IO.inspect(:timer.tc(fn -> byte_size(BertInt.zip(data, 7)) end))
end

IO.puts("ezstd")
for _i <- 1..3 do
  IO.inspect(:timer.tc(fn -> byte_size(:ezstd.compress(data, 11)) end))
end
