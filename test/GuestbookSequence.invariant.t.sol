// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Guestbook} from "src/Guestbook.sol";

/// @dev The model uses submitted commands, never balances/allowances read back from the token.
/// Approvals are separate actions, so signing and delegated spending encounter stale,
/// exhausted, revoked and infinite allowances across arbitrary interleavings.
contract GuestbookSequenceHandler is Test {
    uint256 internal constant COST = 10 ether;
    LaunchToken public immutable token;
    Guestbook public immutable book;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE), address(0xD00D)];
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    bytes32[] public expectedEntries;
    uint256 public voluntaryBurns;
    uint256 public rejectedCalls;

    constructor(LaunchToken token_, Guestbook book_) {
        token = token_;
        book = book_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = 1e27 / actors.length;
        }
    }

    function entryCount() external view returns (uint256) {
        return expectedEntries.length;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % 4];
        address spender = spenderSeed % 5 == 4 ? address(book) : actors[spenderSeed % 5];
        amount = unlimited ? type(uint256).max : bound(amount, 0, 100 * COST);
        bytes memory result = _call(owner, address(token), abi.encodeCall(token.approve, (spender, amount)), "");
        assertTrue(abi.decode(result, (bool)));
        expectedAllowance[owner][spender] = amount;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = _amount(amountSeed, expectedBalance[from]);
        bytes memory failure = _balanceError(from, amount);
        bytes memory result = _call(from, address(token), abi.encodeCall(token.transfer, (to, amount)), failure);
        if (failure.length != 0) return;
        assertTrue(abi.decode(result, (bool)));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = _amount(amountSeed, expectedBalance[actor]);
        bytes memory failure = _balanceError(actor, amount);
        _call(actor, address(token), abi.encodeCall(token.burn, (amount)), failure);
        if (failure.length != 0) return;
        expectedBalance[actor] -= amount;
        voluntaryBurns += amount;
    }

    function spend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed, bool destroy) external {
        address owner = actors[ownerSeed % 4];
        address spender = actors[spenderSeed % 4];
        address to = actors[toSeed % 4];
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        bytes memory failure = _paymentError(owner, spender, amount);
        bytes memory data = destroy
            ? abi.encodeCall(token.burnFrom, (owner, amount))
            : abi.encodeCall(token.transferFrom, (owner, to, amount));
        bytes memory result = _call(spender, address(token), data, failure);
        if (failure.length != 0) return;
        _consumeAllowance(owner, spender, amount);
        expectedBalance[owner] -= amount;
        if (destroy) {
            voluntaryBurns += amount;
        } else {
            assertTrue(abi.decode(result, (bool)));
            expectedBalance[to] += amount;
        }
    }

    function sign(uint256 actorSeed, uint256 lengthSeed, bytes32 content, uint256 elapsedSeed) external {
        address actor = actors[actorSeed % 4];
        uint256 length = bound(lengthSeed, 0, 320);
        bytes memory message = new bytes(length);
        for (uint256 i; i < length; ++i) {
            message[i] = content[i % 32];
        }
        uint256 timestamp = vm.getBlockTimestamp() + bound(elapsedSeed, 0, 1 days);
        vm.warp(timestamp);
        bytes memory failure = length > 280
            ? abi.encodeWithSelector(Guestbook.MessageTooLong.selector, length)
            : _paymentError(actor, address(book), COST);
        bytes memory result = _call(actor, address(book), abi.encodeCall(book.sign, (string(message))), failure);
        if (failure.length != 0) return;
        assertEq(abi.decode(result, (uint256)), expectedEntries.length, "permanent sequential ID");
        expectedEntries.push(keccak256(abi.encode(actor, timestamp, string(message))));
        expectedBalance[actor] -= COST;
        _consumeAllowance(actor, address(book), COST);
    }

    function readSnapshot(uint256 cursorSeed, uint256 limitSeed) external view {
        uint256 cursor = cursorSeed % (expectedEntries.length + 1);
        uint256 limit = 1 + limitSeed % 50;
        (Guestbook.Entry[] memory page, uint256 next) = book.getEntries(cursor, limit);
        assertEq(page.length, cursor < limit ? cursor : limit);
        assertEq(next + page.length, cursor, "cursor must consume exactly the returned entries");
        for (uint256 i; i < page.length; ++i) {
            assertEq(_hash(page[i]), expectedEntries[cursor - 1 - i], "snapshot changed or reordered");
        }
    }

    function _hash(Guestbook.Entry memory entry) internal pure returns (bytes32) {
        return keccak256(abi.encode(entry.signer, entry.timestamp, entry.message));
    }

    function _amount(uint256 seed, uint256 balance) internal pure returns (uint256) {
        // Deliberately include zero, one wei, exact/full balances, and impossible amounts.
        uint256 mode = seed % 9;
        if (mode == 0) return 0;
        if (mode == 1) return 1;
        if (mode == 2) return COST - 1;
        if (mode == 3) return COST;
        if (mode == 4) return COST + 1;
        if (mode == 5) return balance;
        if (mode == 6) return balance + 1;
        if (mode == 7) return type(uint256).max;
        return bound(seed / 9, 0, balance);
    }

    function _balanceError(address owner, uint256 amount) internal view returns (bytes memory) {
        if (expectedBalance[owner] >= amount) return "";
        return
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, owner, expectedBalance[owner], amount
            );
    }

    function _paymentError(address owner, address spender, uint256 amount) internal view returns (bytes memory) {
        if (expectedAllowance[owner][spender] < amount) {
            return abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, expectedAllowance[owner][spender], amount
            );
        }
        return _balanceError(owner, amount);
    }

    function _consumeAllowance(address owner, address spender, uint256 amount) internal {
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }

    function _call(address caller, address target, bytes memory data, bytes memory failure)
        internal
        returns (bytes memory result)
    {
        vm.prank(caller);
        (bool ok, bytes memory returned) = target.call(data);
        if (failure.length == 0) {
            assertTrue(ok, "valid operation must succeed");
        } else {
            assertFalse(ok, "invalid operation must revert");
            assertEq(returned, failure, "unexpected revert reason");
            ++rejectedCalls;
        }
        return returned;
    }
}

/// @dev No storage deals, token mocks or automatic approval before signing. Every balance
/// originates in the constructor issuance; only the handler can mutate the tracked state.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract GuestbookSequenceInvariantTest is Test {
    LaunchToken internal token;
    Guestbook internal book;
    GuestbookSequenceHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        book = new Guestbook(address(token));
        handler = new GuestbookSequenceHandler(token, book);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 1e27 / 4);
            handler.approve(i, 4, 20 ether, i % 2 == 0);
            handler.approve(i, (i + 1) % 4, 30 ether, false);
        }
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.approve.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.burn.selector;
        selectors[3] = handler.spend.selector;
        selectors[4] = handler.sign.selector;
        selectors[5] = handler.readSnapshot.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAllowancesAndImmutableHistoryMatchCommands() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "wrong account charged or credited");
            sum += token.balanceOf(actor);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
            assertEq(token.allowance(actor, address(book)), handler.expectedAllowance(actor, address(book)));
        }
        uint256 count = handler.entryCount();
        assertEq(book.entryCount(), count, "failed or voluntary burns must not append entries");
        assertEq(token.totalSupply(), sum);
        assertEq(sum + handler.voluntaryBurns() + count * 10 ether, 1e27);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(book)), 0, "signing burns; it does not collect fees");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(address(book.token()), address(token));
        for (uint256 i; i < count; ++i) {
            Guestbook.Entry memory entry = book.getEntry(i);
            assertEq(
                keccak256(abi.encode(entry.signer, entry.timestamp, entry.message)),
                handler.expectedEntries(i),
                "an earlier entry was changed"
            );
        }
    }

    function testSeededSequenceExercisesSharedAllowanceAndPaymentRecovery() public {
        // The same finite approval authorizes transfers and burns, not one budget for each.
        handler.spend(0, 1, 2, 3, false); // transfer ten
        handler.spend(0, 1, 2, 3, true); // burn ten
        handler.spend(0, 1, 0, 3, false); // self-transfer consumes the last ten
        invariant_balancesAllowancesAndImmutableHistoryMatchCommands();
        handler.spend(0, 1, 2, 1, true); // exhausted approval: reject one wei
        handler.approve(0, 4, 0, false);
        handler.sign(0, 32, bytes32("revoked"), 1);
        invariant_balancesAllowancesAndImmutableHistoryMatchCommands();
        handler.approve(0, 4, 10 ether, false);
        handler.sign(0, 281, bytes32("too long"), 1); // does not consume approval
        handler.sign(0, 280, bytes32("paid"), 1);
        invariant_balancesAllowancesAndImmutableHistoryMatchCommands();
        handler.transfer(1, 2, 5); // entire balance leaves actor 1
        handler.sign(1, 0, bytes32(0), 1); // sufficient approval, empty balance
        invariant_balancesAllowancesAndImmutableHistoryMatchCommands();
        handler.transfer(2, 1, 3); // replenish with exactly one signing payment
        handler.sign(1, 0, bytes32(0), 0);
        handler.readSnapshot(2, 49);
        invariant_balancesAllowancesAndImmutableHistoryMatchCommands();
        assertEq(book.entryCount(), 2);
        assertEq(handler.voluntaryBurns(), 10 ether);
        assertEq(handler.rejectedCalls(), 4);
    }
}
