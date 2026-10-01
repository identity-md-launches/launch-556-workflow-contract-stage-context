# Guestbook contracts

An append-only onchain guestbook. Every successful `sign(message)` destroys **10 GUEST** from the caller and stores their address, the block timestamp, and a message of **at most 280 bytes**. The contracts are immutable and have no owner, pause, moderation, withdrawal, or upgrade powers.

This contribution supplies contracts, tests, vendored dependencies, ABI exports, and the frontend/deployment handoff. The manifest writer supplies `launch.json`; independent review examines these contracts and the concrete manifest together. Publishing source to GitHub, attestation, admission, deployment, and starting/publishing the website to IPFS belong to the later services. No chain transactions have been broadcast.

## Token and burn semantics

`LaunchToken` has no constructor arguments. It is named **Guestbook**, symbol **GUEST**, with **18 decimals**. Its constructor mints exactly **1,000,000,000 tokens (10^27 minor units)** to `msg.sender`, which is the project factory in production. There are no further mint paths or privileged roles. Transfers are standard ERC-20 transfers with no fees, blocklists, or implicit burns.

The brief explicitly asks for burning. This implementation interprets fixed supply as **fixed initial issuance with no inflation**, and uses OpenZeppelin's explicit `burn`/`burnFrom` extension: each guestbook signature reduces `totalSupply()` by `10^19` minor units. It does not send tokens to a dead-address balance. Holders can also burn their own tokens, or authorize another spender to burn using an allowance. Such voluntary burns create no guestbook entries. Neither application construction nor ordinary transfers reduce supply. Independent review must retain this explicit burn behavior when checking the launch policy and manifest.

The factory performs the protocol allocation of the initial supply (10% contributor/network allocation and 90% requester allocation, including pool liquidity). These contracts do not allocate or forward any of that supply, and the guestbook receives none during construction. The fixed signing charge is independent of gas or pool trading fees.

## Signing and reading

1. Acquire at least 10 GUEST and native currency for transaction gas on the deployment chain.
2. On `LaunchToken`, call `approve(guestbookAddress, 10000000000000000000)` and wait for confirmation.
3. Call `Guestbook.sign(message)` with zero ETH. Wait for confirmation and read the `Signed` event to obtain the ID. A wallet transaction receipt does not expose the Solidity return value.

The guestbook can only charge `msg.sender`. Finite allowance is consumed on a successful signature; missing/revoked/insufficient allowance or an insufficient balance reverts the whole transaction, including the entry, burn, allowance update, and logs. Gas spent on a reverted transaction is not refunded. Use exact approval per signature; the underlying standard token also supports unlimited allowances, which remain outstanding until revoked.

Empty messages, duplicate text, and repeated signatures by the same account are permitted and each costs 10 tokens. The workflow specifies no minimum length or per-wallet limit. The 280-byte cap includes UTF-8 multibyte characters; for example, 70 four-byte emoji use the whole limit. Solidity does not validate UTF-8, so onchain data may contain arbitrary bytes. Entries cannot be edited or deleted. There is no deadline, payout, refund, randomness, or round lifecycle.

For the latest entries, read `entryCount()` and pass that number as the exclusive `beforeId` to `getEntries(beforeId, limit)`. Results are newest first, with a limit of 1–50. The returned `nextBeforeId` is the next page's cursor; zero means the end. Entry IDs are `beforeId - 1 - indexInPage`. Starting with a captured count gives a stable snapshot even if more signatures arrive between page requests. Read a single record with `getEntry(id)`. See [ABI and integration details](docs/ABI.md).

## Deployment parameters and responsibilities

| Deployment order | Source / contract | Constructor arguments | ETH value |
| --- | --- | --- | --- |
| Launch token | `src/LaunchToken.sol:LaunchToken` | none | 0 |
| Application | `src/Guestbook.sol:Guestbook` | `address tokenAddress` = `$token` | 0 |

The application identifier is `Guestbook`. Its constructor is fully configuring and nonpayable. It needs no initialization call, owner argument, or privileged wallet. It validates that its token has code and 18 decimals; those checks do **not** authenticate arbitrary token implementations. The manifest must reference the accepted `LaunchToken` deployment, not an external or substituted token. The token address is immutable afterward.

The manifest/service team supplies the target chain and predicted addresses, source and signed-artifact linkage, and policy-derived owner and distribution parameters. No network address was supplied or hard-coded here. For the default native-currency launch, the canonical pool input is the zero currency address, admission fee 3000, tick spacing 60, and legacy initial price `79228162514264337593543950336`. Current policy derives the effective opening price and the factory reads the trading fee from the network's LaunchFees contract (1.25% by default). Admission fee 3000 does not describe the trading fee. The factory supplies the pool guard and reward distributor; neither is an application in this source contribution.

Services must complete independent source/manifest review before release, then publish/attest/admit/deploy through the factory and verify deployed source. The website must use the confirmed deployment chain, token and guestbook addresses, these ABIs, and the exact pool key in the deployment handoff for any trading UI. Its build, IPFS publication, and RPC configuration are the frontend/service responsibilities.

## Build and checks

Foundry is configured with **Solidity 0.8.26**, optimizer 200 runs, Paris EVM, and `bytecode_hash = "none"`. All Solidity dependencies are vendored as ordinary files with their licenses; see [dependency provenance](DEPENDENCIES.md). With Foundry and the pinned compiler installed, building and testing require no network. FFI and filesystem cheatcode permissions are disabled. Tests do not use environment configuration, keys, or RPC endpoints.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py --check
```

After changing a public interface, regenerate the delivered ABI files with `python3 scripts/export_abis.py`. The files are [LaunchToken.json](docs/abi/LaunchToken.json) and [Guestbook.json](docs/abi/Guestbook.json).

Tests cover supply, ERC-20 transfer/approval/burn accounting, unauthorized calls, factory-style CREATE2 constructors, runtime size/forbidden opcodes, entry persistence/events, byte limits including UTF-8, zero/repeated messages, stable pagination, ETH rejection, failed payments, and reentrancy with rollback. Fuzz tests exercise messages, pagination, and token conservation. A stateful invariant combines signatures, transfers, voluntary burns, and failed unapproved signatures across three wallets, checking balances plus all burns against the initial issuance (128 sequences of 64 calls).

## Trust and operational assumptions

The production token is exactly this immutable `LaunchToken`; it has no callbacks. The guestbook additionally uses a reentrancy guard and records effects before calling `burnFrom`. Foundry's `reentrancy-no-eth` heuristic may flag the guard's post-call status reset; nested-call tests verify that the lock is already active before the burn, and reverting token callbacks undo both contracts' state. This warning is reviewed here, not suppressed. Slither and Mythril were not run. Local tests and this assessment are not the independent adversarial review required before release.

Normal signing leaves no token or ETH custody in the guestbook. Directly transferred tokens or forcibly sent ETH cannot be recovered, because there is no rescue function. There is no administrator capable of restoring burned tokens or removing sensitive messages. Treat signatures and messages as public permanent data. The website must display untrusted text as text, never HTML; validate UTF-8 byte length before sending, handle malformed onchain text defensively, and show chain/account changes and transaction failures. Timestamps are chain-provided display metadata, not an ordering guarantee; entry IDs define transaction order. Reorg-aware indexing and confirmation policy belong to the frontend service.
