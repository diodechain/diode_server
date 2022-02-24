# Emergency Measures

These are some common measures that can be taken when there is a seeming data corruption on the node.

## Disable the EDGE interfaces:

For this you need a `./remsh` it will disable edge communication and thus reduce error noise:

```
Supervisor.terminate_child(Diode.Supervisor, Network.EdgeV2)
```

## Delete a couple of peak blocks

Ensure that the node is down before doing this!

In case the node does not even startup, but instead bails out with database errors. This is run from bash but requires the `sqlite3` command line tool installed. E.g. in debian/ubuntu you can get it with `sudo apt install sqlite3`

```
sqlite3 data_prod/blockchain.sq3 "DELETE FROM blocks WHERE number > (SELECT MAX(number) FROM blocks) - 5"
```

## Delete the blockcache

Ensure that the node is down before doing this!

In case the bockcache is corrupted go ahead and delete it:

```
rm data_prod/blockcache.*
```