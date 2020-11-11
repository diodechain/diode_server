# Todo

* Improve performance
```
num = 993210  
block = Chain.block(num)  
p = Chain.Block.parent(block) 
Chain.Block.validate(block, p)
pid = spawn(fn -> for _ <- 1..100_000, do: Chain.Block.validate(block, p) end)
```

* Remove .receipts from block only keep in cache
* Add Merkle Inclusion Proof
  * Generate optimal (shortest) proof path
