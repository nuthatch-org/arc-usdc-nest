# arc-usdc-nest

A [nuthatch](https://github.com/nuthatch-org/nuthatch) nest: **USDC on Arc testnet**, Circle's EVM L1.

Both faces of USDC on Arc, decoded into SQL tables on your own machine: the ERC-20 interface at
`0x3600…0000` and the native USDC system emitter at `0xffff…fffe`, which logs every movement of the
gas token. Two views put them together without counting a transfer twice.

One binary, one config file, no Postgres, no Docker, no API key.

## What it indexes

**Chain:** `arc-testnet`, chain id 5042002. **2 contracts**, **11 tables**, from block 72,550,000.
The chain id, RPC endpoints and addresses are from Arc's docs
([connect](https://docs.arc.io/arc/references/connect-to-arc),
[contract addresses](https://docs.arc.io/arc/references/contract-addresses),
[USDC system events](https://docs.arc.io/arc/references/usdc-system-events)), read on 2026-11-17.

| alias | contract | address | decimals |
|---|---|---|---|
| `usdc` | USDC, ERC-20 interface (FiatToken proxy) | `0x3600000000000000000000000000000000000000` | 6 |
| `native` | native USDC system emitter (EIP-7708) | `0xfffffffffffffffffffffffffffffffffffffffe` | 18 |

`native` has no code. It is the address Arc logs a standard `Transfer` from whenever native USDC
moves, so its ABI is that one event.

## Verified

Measured on 2026-11-17 with nuthatch 5.22.0 on an 18-core M5 Pro, against the two keyless public
endpoints in `nuthatch.toml`. One run, not a benchmark.

- `nuthatch dev --dir . --poll-interval 2s` backfilled from block 72,550,000 and caught up to the
  tip at block 72,728,433 with **1,386,556 events in 17 m 13 s** (1,341 events a second). The
  178,433 blocks are about 32 hours. Both endpoints answered 429 throughout (164 lines in the log)
  and nuthatch waited each one out. An earlier run the same day, on a fresher quota and with a third
  endpoint, took 5 m 09 s over about the same range.
- Peak RSS over the run was 490 MB. Disk after it: 80 MB of sealed segments, 27 MB of hot store.
- Following at a 2 s poll, it read 5 or 6 blocks behind the tip once a minute.
- **Checked against Arc's explorer.** For blocks 72,700,000 to 72,700,199 the explorer's `getLogs`
  API returns 650 logs for `0x3600` and 788 for `0xffff…fffe`. The nest holds the same 650 (592
  transfers, 55 approvals, 2 burns, 1 mint) and the same 788. For blocks 72,700,000 to 72,700,999,
  `eth_getLogs` on QuickNode returns 2,932 ERC-20 transfers, 150 approvals and 3,958 native
  transfers, as the nest does.
- **The two faces agree.** Up to block 72,728,000 there are 792,404 native movements. 536,002 are
  the twins of ERC-20 transfers and 256,402 are `native_only`. The ERC-20 transfers with no twin are
  the zero-value ones and 71 self-transfers, whose `from` and `to` are the same address: Arc logs
  neither from the emitter.
- A restart after a minute and a half down was back at the tip in 1 s. The queries below answered
  in under half a second.

## Arc's quirks, as they bear on an indexer

- **USDC is the gas token, and it logs twice.** A transfer through `0x3600` emits its own 6-decimal
  `Transfer` and an 18-decimal `Transfer` from `0xffff…fffe` in the same transaction. A plain value
  send emits only the second. Count from `native__transfer` for every movement, or add
  `usdc__transfer` to `native_only`; never add the two tables. Zero-value transfers and
  self-transfers through `0x3600` have no native twin.
- **Never mix the decimals.** `usdc__transfer.value` has 6, `native__transfer.value` has 18.
- **The public RPC refuses more than ten topic0s in one `eth_getLogs`**, answering
  `-32012 requested range too large` even for one block. The FiatToken ABI has 17 events, so this nest
  lists ten in `events =` in `nuthatch.toml`: transfers, approvals, mints, burns, minter allowances,
  `AuthorizationUsed`, blacklisting and pausing. Owner and role changes, `MinterRemoved` and
  `AuthorizationCanceled` are not indexed. Add one only by removing another.
- **Before the Zero5 hard fork, native movements were logged differently**, as `NativeCoin*` events
  from `0x1800…0000`. This nest starts after it (the emitter already logs at its first block)
  and does not decode that era. Arc's docs give the activation in the arc-node changelog rather
  than as a block number.
- **Blocks came about every 0.6 s** in the range measured, and are final when they are made:
  `finalized` is the head. Nuthatch has no Arc entry in its chain registry, so it treats Arc as an
  unregistered chain: 64 blocks of finality depth, about 40 seconds, before a segment seals.
- **Endpoints.** `rpc.testnet.arc.io` (Circle) and `rpc.quicknode.testnet.arc.io` both answer
  without a key, and both answer `429` under a sustained backfill; nuthatch waits and carries on.
  Blockdaemon's keyless endpoint sent a gzip body to a curl request that had not asked for one,
  and nuthatch logged its answers as malformed, so it is left out. dRPC's free tier answered a
  512-block range with "ranges over 10000 blocks are not supported on free plan".

## Run it

```sh
nuthatch init --from https://github.com/nuthatch-org/arc-usdc-nest
cd arc-usdc-nest
nuthatch dev --dir .
nuthatch sql --dir . "SELECT * FROM movements_hourly ORDER BY hour DESC LIMIT 5"
```

`dev` backfills from block 72,550,000. To start later, change `start_block` for both contracts, or
pass `--backfill <blocks>` on a first run. History before Zero5 needs the `0x1800` events added.

## Views

- `native_only`: native movements with no ERC-20 twin in the same transaction (value sends, mints,
  burns, contract-internal moves). `native_only` plus `usdc__transfer` is every movement once.
- `movements_hourly`: every native movement per hour, with mints, burns and `value_raw`
  (18 decimals).

```sql
-- native USDC moved per hour on Arc, from the system emitter
SELECT hour, movements, mints, burns, value_raw / 1e18 AS usdc
FROM movements_hourly ORDER BY hour DESC LIMIT 3;
```

```
 hour       | movements | mints | burns | usdc
------------+-----------+-------+-------+--------------------
 1794942000 | 7624      | 28    | 56    | 57240.587511118276
 1794938400 | 20535     | 3     | 125   | 146194.14427631022
 1794934800 | 22267     | 10    | 140   | 370197.04669257556
```

The first row is the hour still in progress.

```sql
-- how USDC moves: through the ERC-20 interface, or natively
SELECT 'via ERC-20' AS path, count(*) AS movements FROM usdc__transfer WHERE value_dec > 0
UNION ALL
SELECT 'native only', count(*) FROM native_only;
```

```
 path        | movements
-------------+-----------
 via ERC-20  | 537427
 native only | 257176
```

```sql
-- one block range, both tables, as checked against the explorer
SELECT (SELECT count(*) FROM usdc__transfer WHERE block_number BETWEEN 72700000 AND 72700199) AS erc20,
       (SELECT count(*) FROM native__transfer WHERE block_number BETWEEN 72700000 AND 72700199) AS native;
```

```
 erc20 | native
-------+--------
 592   | 788
```

`from` and `to` are reserved words in SQL, so quote them. `value_raw / 1e18` is a float, fine for
reading and not for accounting; keep `value_raw` for sums you will check.

## Query it without installing anything

A live, read-only copy of this nest runs at **https://arc.nuthatch-indexer.com**: Arc testnet, following the tip, no key, no
sign-up. It is the same nest as above on someone else's machine, so every query in this README works
against it. It is rate-limited per address (30 queries a minute) and each query is cut off at 10 seconds
and 5,000 rows.

```sh
# the five newest USDC transfers
curl -sG "https://arc.nuthatch-indexer.com/sql" --data-urlencode \
  'q=SELECT block_number, tx_hash, "from", "to", value_dec FROM usdc__transfer ORDER BY block_number DESC, log_index DESC LIMIT 5'

# native USDC moved per hour, from the system emitter
curl -sG "https://arc.nuthatch-indexer.com/sql" --data-urlencode \
  'q=SELECT hour, movements, mints, burns, value_raw / 1e18 AS usdc FROM movements_hourly ORDER BY hour DESC LIMIT 3'

# how USDC moves: through the ERC-20 interface, or natively
curl -sG "https://arc.nuthatch-indexer.com/sql" --data-urlencode \
  "q=SELECT 'via ERC-20' AS path, count(*) AS movements FROM usdc__transfer WHERE value_dec > 0 UNION ALL SELECT 'native only', count(*) FROM native_only"
```

Every answer says how fresh it is: `provenance.as_of` is the block it was computed at, and `GET https://arc.nuthatch-indexer.com/ready`
reports `lag_blocks` behind the Arc tip.

For an agent, the same nest speaks MCP over HTTP. With Claude Code:

```sh
claude mcp add --transport http arc-usdc https://arc.nuthatch-indexer.com/mcp
```

or check what it offers first:

```sh
curl -s https://arc.nuthatch-indexer.com/mcp -H 'content-type: application/json' -H 'accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

It serves reads only: `SELECT` and `WITH`, nothing that writes, and no admin routes.
