// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Guestbook} from "src/Guestbook.sol";

/// @dev A forwarding caller to distinguish msg.sender from tx.origin in payment and authorship.
contract GuestbookSigningCaller {
    function sign(LaunchToken token, Guestbook book, string calldata message) external returns (uint256) {
        token.approve(address(book), 10 ether);
        return book.sign(message);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract AdversarialBoundariesTest is Test {
    uint256 internal constant SUPPLY = 1e27;
    uint256 internal constant COST = 10 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    LaunchToken internal token;
    Guestbook internal book;

    function setUp() public {
        token = new LaunchToken();
        book = new Guestbook(address(token));
    }

    function testFuzzPaymentAndLengthChecksAreAtomicAndRecoverable(
        uint256 balanceSeed,
        uint256 allowanceSeed,
        uint256 lengthSeed,
        bytes32 content,
        bool unlimited
    ) public {
        token.approve(address(book), COST);
        book.sign("already paid");
        Guestbook.Entry memory original = book.getEntry(0);
        uint256 balance = bound(balanceSeed, 0, 2 * COST);
        uint256 allowance = unlimited ? type(uint256).max : bound(allowanceSeed, 0, 2 * COST);
        uint256 length = bound(lengthSeed, 0, 560);
        bytes memory message = new bytes(length);
        for (uint256 i; i < length; ++i) {
            message[i] = content[i % 32];
        }
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        token.approve(address(book), allowance);

        bytes memory expectedError;
        if (length > 280) {
            expectedError = abi.encodeWithSelector(Guestbook.MessageTooLong.selector, length);
        } else if (allowance < COST) {
            expectedError = abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(book), allowance, COST
            );
        } else if (balance < COST) {
            expectedError = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, COST);
        }

        if (expectedError.length == 0) {
            vm.prank(ALICE);
            assertEq(book.sign(string(message)), 1);
            assertEq(book.getEntry(1).signer, ALICE);
            assertEq(bytes(book.getEntry(1).message), message);
            assertEq(token.balanceOf(ALICE), balance - COST);
            assertEq(token.totalSupply(), SUPPLY - 2 * COST);
            assertEq(token.allowance(ALICE, address(book)), unlimited ? allowance : allowance - COST);
        } else {
            vm.expectRevert(expectedError);
            vm.prank(ALICE);
            book.sign(string(message));
            assertEq(book.entryCount(), 1);
            assertEq(token.balanceOf(ALICE), balance);
            assertEq(token.totalSupply(), SUPPLY - COST);
            assertEq(token.allowance(ALICE, address(book)), allowance);
            vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryNotFound.selector, 1));
            book.getEntry(1);

            // Fix all preconditions. A failed payment must not consume an ID or leave the guard locked.
            if (balance < COST) token.transfer(ALICE, COST - balance);
            vm.startPrank(ALICE);
            token.approve(address(book), COST);
            assertEq(book.sign("retry after failure"), 1);
            vm.stopPrank();
            assertEq(token.totalSupply(), SUPPLY - 2 * COST);
            assertEq(token.allowance(ALICE, address(book)), 0);
            assertEq(token.balanceOf(ALICE), balance < COST ? 0 : balance - COST);
        }
        assertEq(book.entryCount(), 2);
        Guestbook.Entry memory preserved = book.getEntry(0);
        assertEq(keccak256(abi.encode(preserved)), keccak256(abi.encode(original)));
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testContractCallerPaysAndIsRecordedInsteadOfTransactionOrigin() public {
        GuestbookSigningCaller caller = new GuestbookSigningCaller();
        token.transfer(ALICE, COST);
        vm.prank(ALICE);
        token.approve(address(book), COST);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(caller), 0, COST)
        );
        vm.prank(ALICE, ALICE);
        caller.sign(token, book, "origin has funds, caller does not");
        assertEq(book.entryCount(), 0);
        assertEq(token.balanceOf(ALICE), COST);
        assertEq(token.allowance(ALICE, address(book)), COST);
        assertEq(token.allowance(address(caller), address(book)), 0);

        token.transfer(address(caller), COST);
        vm.prank(ALICE, ALICE);
        assertEq(caller.sign(token, book, "contract wallet"), 0);
        assertEq(book.getEntry(0).signer, address(caller));
        assertEq(book.getEntry(0).message, "contract wallet");
        assertEq(token.balanceOf(address(caller)), 0);
        assertEq(token.allowance(address(caller), address(book)), 0);
        assertEq(token.balanceOf(ALICE), COST);
        assertEq(token.allowance(ALICE, address(book)), COST);
        assertEq(token.totalSupply(), SUPPLY - COST);
    }

    function testApprovalsAreIsolatedAcrossGuestbooks() public {
        Guestbook second = new Guestbook(address(token));
        token.approve(address(book), COST);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(second), 0, COST)
        );
        second.sign("approval belongs to the other book");
        assertEq(book.entryCount(), 0);
        assertEq(second.entryCount(), 0);
        assertEq(token.allowance(address(this), address(book)), COST);
        assertEq(token.totalSupply(), SUPPLY);

        token.approve(address(second), 2 * COST);
        assertEq(book.sign("first book"), 0);
        assertEq(second.sign("second book"), 0);
        assertEq(book.getEntry(0).message, "first book");
        assertEq(second.getEntry(0).message, "second book");
        assertEq(token.allowance(address(this), address(book)), 0);
        assertEq(token.allowance(address(this), address(second)), COST);
        assertEq(token.totalSupply(), SUPPLY - 2 * COST);
    }

    function testFullSupplyDelegatedTransferAndBurnReachZeroWithoutFreeSigning() public {
        token.approve(ALICE, SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(BOB), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(address(this), ALICE), 0);
        vm.prank(BOB);
        token.approve(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.burnFrom(BOB, SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(BOB, ALICE), 0);
        assertEq(book.entryCount(), 0, "voluntary burns must not create signatures");

        vm.startPrank(BOB);
        assertTrue(token.transfer(ALICE, 0));
        token.burn(0);
        token.approve(address(book), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, COST));
        book.sign("");
        vm.stopPrank();
        assertEq(book.entryCount(), 0);
        assertEq(token.allowance(BOB, address(book)), type(uint256).max);
        assertEq(token.totalSupply(), 0);
    }

    function testFuzzDelegatedSelfTransferConsumesOnlyFiniteAllowance(uint256 amount, bool unlimited) public {
        amount = bound(amount, 0, SUPPLY);
        uint256 allowance = unlimited ? type(uint256).max : amount;
        token.approve(ALICE, allowance);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), address(this), amount));
        assertEq(token.allowance(address(this), ALICE), unlimited ? allowance : 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumOverdraftRevertsAndRestoresDelegatedAllowance() public {
        uint256 excessive = type(uint256).max;
        bytes memory expectedError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, excessive);
        token.approve(ALICE, excessive);
        vm.expectRevert(expectedError);
        token.transfer(BOB, excessive);
        vm.expectRevert(expectedError);
        token.burn(excessive);
        vm.startPrank(ALICE);
        vm.expectRevert(expectedError);
        token.transferFrom(address(this), BOB, excessive);
        vm.expectRevert(expectedError);
        token.burnFrom(address(this), excessive);
        vm.stopPrank();
        assertEq(token.allowance(address(this), ALICE), excessive);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);

        // The finite case actually decrements allowance before the balance check, then rolls it back.
        token.approve(ALICE, SUPPLY + 1);
        expectedError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1);
        vm.expectRevert(expectedError);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, SUPPLY + 1);
        assertEq(token.allowance(address(this), ALICE), SUPPLY + 1);
        vm.expectRevert(expectedError);
        vm.prank(ALICE);
        token.burnFrom(address(this), SUPPLY + 1);
        assertEq(token.allowance(address(this), ALICE), SUPPLY + 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testZeroReceiverRevertsWithoutConsumingDelegatedApproval() public {
        token.approve(ALICE, COST);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(address(this), address(0), COST);
        assertEq(token.allowance(address(this), ALICE), COST);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumReadBoundsOnNonemptyBookUseCustomErrors() public {
        token.approve(address(book), COST);
        book.sign("stored");
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryNotFound.selector, type(uint256).max));
        book.getEntry(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidCursor.selector, type(uint256).max, 1));
        book.getEntries(type(uint256).max, 50);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidPageSize.selector, type(uint256).max));
        book.getEntries(1, type(uint256).max);
        (Guestbook.Entry[] memory page, uint256 next) = book.getEntries(1, 50);
        assertEq(page.length, 1);
        assertEq(page[0].message, "stored");
        assertEq(next, 0);
    }
}
