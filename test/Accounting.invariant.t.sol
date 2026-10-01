// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook} from "../src/Guestbook.sol";

contract AccountingHandler is Test {
    LaunchToken public immutable token;
    Guestbook public immutable book;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    uint256 public signatures;
    uint256 public voluntaryBurns;
    uint256[3] public signedByActor;

    constructor(LaunchToken token_, Guestbook book_) {
        token = token_;
        book = book_;
    }

    function sign(uint256 actorSeed, bytes32 message) external {
        uint256 index = actorSeed % actors.length;
        address actor = actors[index];
        uint256 cost = book.SIGNING_COST();
        if (token.balanceOf(actor) < cost) return;
        vm.startPrank(actor);
        token.approve(address(book), cost);
        uint256 id = book.sign(string(abi.encodePacked(message)));
        vm.stopPrank();
        assertEq(id, signatures);
        ++signatures;
        ++signedByActor[index];
        Guestbook.Entry memory entry = book.getEntry(id);
        assertEq(entry.signer, actor);
        assertEq(bytes(entry.message), abi.encodePacked(message));
        assertEq(token.allowance(actor, address(book)), 0);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256 supply = token.totalSupply();
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        assertEq(token.totalSupply(), supply);
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.burn(amount);
        voluntaryBurns += amount;
    }

    function attemptUnapprovedSignature(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(actor);
        vm.startPrank(actor);
        token.approve(address(book), 0);
        (bool ok,) = address(book).call(abi.encodeCall(book.sign, ("no approval")));
        vm.stopPrank();
        assertFalse(ok);
        assertEq(book.entryCount(), signatures);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(actor), balance);
    }
}

contract AccountingInvariantTest is Test {
    LaunchToken internal token;
    Guestbook internal book;
    AccountingHandler internal handler;

    function setUp() public {
        token = new LaunchToken();
        book = new Guestbook(address(token));
        handler = new AccountingHandler(token, book);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 10_000 ether);
        }
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = AccountingHandler.sign.selector;
        selectors[1] = AccountingHandler.transfer.selector;
        selectors[2] = AccountingHandler.burn.selector;
        selectors[3] = AccountingHandler.attemptUnapprovedSignature.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantSupplyBalancesAndPaidEntriesStayInSync() public view {
        uint256 balanceSum = token.balanceOf(address(this));
        uint256 signatures;
        for (uint256 i; i < 3; ++i) {
            balanceSum += token.balanceOf(handler.actors(i));
            signatures += handler.signedByActor(i);
        }
        assertEq(signatures, handler.signatures());
        assertEq(book.entryCount(), signatures);
        assertEq(balanceSum, token.totalSupply());
        assertEq(token.totalSupply() + handler.voluntaryBurns() + signatures * 10 ether, 1e27);
        assertEq(token.balanceOf(address(book)), 0);
    }
}
