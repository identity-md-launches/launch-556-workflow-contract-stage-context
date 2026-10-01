# Contract ABI and website handoff

Machine-readable, compiler-generated ABI arrays:

- [`abi/LaunchToken.json`](abi/LaunchToken.json)
- [`abi/Guestbook.json`](abi/Guestbook.json)

Generate with `python3 scripts/export_abis.py`; check with `python3 scripts/export_abis.py --check`. All amounts are integer minor units. GUEST has 18 decimals and the signing cost is `10000000000000000000`. All writes are nonpayable.

## LaunchToken

Constructor: `constructor()`.

| Function | Behavior |
| --- | --- |
| `name()`, `symbol()`, `decimals()` | `Guestbook`, `GUEST`, `18` |
| `totalSupply()` | Initially `10^27`; falls only on explicit burns |
| `balanceOf(address)` | Current account balance |
| `allowance(address owner, address spender)` | Current authorization for transfers or burns |
| `approve(address spender, uint256 value)` | Sets allowance; returns true and emits `Approval` |
| `transfer(address to, uint256 value)` | Plain transfer; returns true |
| `transferFrom(address from, address to, uint256 value)` | Allowance-authorized transfer; returns true |
| `burn(uint256 value)` | Burns caller's tokens, lowering supply |
| `burnFrom(address account, uint256 value)` | Burns with caller's allowance from account |

Transfers and burns emit `Transfer(address indexed from, address indexed to, uint256 value)`; burn destination is zero. Finite spending decreases allowance without an `Approval` event in this OpenZeppelin version, so refresh `allowance()` after confirmation. `uint256.max` allowance is not consumed. ERC-20 failures use the standard custom errors in the ABI, especially `ERC20InsufficientAllowance` and `ERC20InsufficientBalance`.

## Guestbook

Constructor: `constructor(address tokenAddress)`; supply the accepted launch token (`$token`).

| Function | Result / behavior |
| --- | --- |
| `token()` | Immutable launch-token address |
| `SIGNING_COST()` | `10^19` minor units |
| `MAX_MESSAGE_BYTES()` | 280 |
| `MAX_PAGE_SIZE()` | 50 |
| `sign(string message)` | Burns caller's 10 tokens; returns new `uint256 entryId` |
| `entryCount()` | Number of stored entries; next entry's ID |
| `getEntry(uint256 entryId)` | One `Entry` tuple; rejects nonexistent IDs |
| `getEntries(uint256 beforeId, uint256 limit)` | `(Entry[] entries, uint256 nextBeforeId)`, newest first |

`Entry` is `(address signer, uint256 timestamp, string message)`. Timestamp is Unix seconds. IDs start at zero and never shift. `getEntries` uses an exclusive upper bound, requires `beforeId <= entryCount()` and `1 <= limit <= 50`, and returns at most `min(beforeId, limit)` entries. For example, with five entries, `getEntries(5, 2)` returns IDs 4 and 3 and cursor 3; `getEntries(3, 2)` returns IDs 2 and 1 and cursor 1; `getEntries(1, 2)` returns ID 0 and cursor 0. `getEntries(0, 2)` returns an empty array and zero.

Event: `Signed(uint256 indexed entryId, address indexed signer, uint256 timestamp, string message)`. It is emitted before the token interaction and is reverted if the burn fails. A confirmed successful receipt contains both this event and the token burn's `Transfer` event. Index logs using chain, contract address, transaction hash, and log index; account for reorgs. Refresh from `entryCount()` to include newer messages.

| Custom error | Meaning |
| --- | --- |
| `InvalidToken(address)` | Constructor token has no code, including zero |
| `InvalidTokenDecimals(uint8)` | Constructor token does not report 18 decimals |
| `MessageTooLong(uint256)` | Message length exceeds 280 bytes |
| `EntryNotFound(uint256)` | ID is at or beyond the current count |
| `InvalidCursor(uint256,uint256)` | Read cursor exceeds the count |
| `InvalidPageSize(uint256)` | Page limit is zero or greater than 50 |
| `ReentrancyGuardReentrantCall()` | Nested signing attempted during a token call |

Token errors bubble up from `sign`; decode using both ABI files. An unsupported token metadata interface reverts during construction.

## Wallet flow

Use the deployment handoff's chain ID and addresses, check the connected network, read the signing cost and user's balance/allowance, and request exact approval if needed. Wait for the approval receipt before sending `sign(message)` with zero ETH. Use `new TextEncoder().encode(message).length <= 280` for browser validation. Render returned messages as text, including strings that resemble scripts or markup. Empty messages and repeated messages are valid. Handle malformed UTF-8 entries without allowing one entry to break the entire feed; individual `getEntry(id)` reads can isolate decoding failures. A failed signing transaction stores nothing and burns no tokens; any separately confirmed approval remains available until spent or revoked.
