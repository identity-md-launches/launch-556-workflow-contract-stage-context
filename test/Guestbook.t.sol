// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook} from "../src/Guestbook.sol";

contract GuestbookTest is Test {
    LaunchToken internal token;
    Guestbook internal book;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant COST = 10 ether;
    uint256 internal constant SUPPLY = 1e27;

    event Signed(uint256 indexed entryId, address indexed signer, uint256 timestamp, string message);

    function setUp() public {
        token = new LaunchToken();
        book = new Guestbook(address(token));
        token.transfer(ALICE, 1_000 ether);
        token.transfer(BOB, 1_000 ether);
    }

    function testConstructorSetsImmutableConfigurationWithoutMovingSupply() public view {
        assertEq(address(book.token()), address(token));
        assertEq(book.SIGNING_COST(), COST);
        assertEq(book.MAX_MESSAGE_BYTES(), 280);
        assertEq(book.MAX_PAGE_SIZE(), 50);
        assertEq(book.entryCount(), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(book)), 0);
    }

    function testConstructorRejectsZeroAndEOATokens() public {
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidToken.selector, address(0)));
        new Guestbook(address(0));
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidToken.selector, ALICE));
        new Guestbook(ALICE);
    }

    function testConstructorRejectsWrongDecimals() public {
        WrongDecimalsToken wrongToken = new WrongDecimalsToken();
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidTokenDecimals.selector, uint8(6)));
        new Guestbook(address(wrongToken));
    }

    function testSignBurnsExactlyTenAndStoresAuthorTimeMessage() public {
        vm.warp(123456);
        vm.startPrank(ALICE);
        token.approve(address(book), COST);
        vm.expectEmit(true, true, false, true, address(book));
        emit Signed(0, ALICE, 123456, "Hello, chain!");
        uint256 id = book.sign("Hello, chain!");
        vm.stopPrank();

        assertEq(id, 0);
        assertEq(book.entryCount(), 1);
        Guestbook.Entry memory entry = book.getEntry(id);
        assertEq(entry.signer, ALICE);
        assertEq(entry.timestamp, 123456);
        assertEq(entry.message, "Hello, chain!");
        assertEq(token.balanceOf(ALICE), 990 ether);
        assertEq(token.balanceOf(BOB), 1_000 ether);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(ALICE, address(book)), 0);
        assertEq(token.totalSupply(), SUPPLY - COST);
    }

    function testEmptyAndRepeatedMessagesAreAllowedAndCharged() public {
        vm.startPrank(ALICE);
        token.approve(address(book), 3 * COST);
        assertEq(book.sign(""), 0);
        assertEq(book.sign("hello"), 1);
        assertEq(book.sign("hello"), 2);
        vm.stopPrank();
        assertEq(book.getEntry(0).message, "");
        assertEq(book.getEntry(1).message, book.getEntry(2).message);
        assertEq(book.entryCount(), 3);
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.totalSupply(), SUPPLY - 3 * COST);
    }

    function testExactly280BytesAccepted() public {
        string memory message = string(new bytes(280));
        _sign(ALICE, message);
        assertEq(bytes(book.getEntry(0).message).length, 280);
        assertEq(book.getEntry(0).message, message);
    }

    function test281BytesRevertsWithoutBurningOrUsingAllowance() public {
        vm.startPrank(ALICE);
        token.approve(address(book), COST);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 281));
        book.sign(string(new bytes(281)));
        vm.stopPrank();
        _assertUnchanged(ALICE, COST);
    }

    function testUtf8LimitCountsBytesNotCharacters() public {
        string memory message;
        for (uint256 i; i < 70; ++i) {
            message = string.concat(message, unicode"😀");
        }
        assertEq(bytes(message).length, 280);
        _sign(ALICE, message);
        assertEq(book.getEntry(0).message, message);

        vm.startPrank(ALICE);
        token.approve(address(book), COST);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, 284));
        book.sign(string.concat(message, unicode"😀"));
        vm.stopPrank();
        assertEq(book.entryCount(), 1);
        assertEq(token.totalSupply(), SUPPLY - COST);
        assertEq(token.allowance(ALICE, address(book)), COST);
    }

    function testMissingApprovalRevertsAndRollsBackEntry() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, COST)
        );
        vm.prank(ALICE);
        book.sign("unpaid");
        _assertUnchanged(ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryNotFound.selector, 0));
        book.getEntry(0);

        // Reversion must also release the guard and leave the first ID available.
        assertEq(_sign(ALICE, "retry"), 0);
    }

    function testShortAndRevokedApprovalsRevert() public {
        vm.startPrank(ALICE);
        token.approve(address(book), COST - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), COST - 1, COST)
        );
        book.sign("short");
        token.approve(address(book), COST);
        token.approve(address(book), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, COST)
        );
        book.sign("revoked");
        vm.stopPrank();
        _assertUnchanged(ALICE, 0);
    }

    function testInsufficientBalanceRestoresApprovalAndEntry() public {
        address poorSigner = address(0xBAD);
        token.transfer(poorSigner, COST - 1);
        vm.startPrank(poorSigner);
        token.approve(address(book), COST);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poorSigner, COST - 1, COST)
        );
        book.sign("short balance");
        vm.stopPrank();
        assertEq(book.entryCount(), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(poorSigner), COST - 1);
        assertEq(token.allowance(poorSigner, address(book)), COST);
    }

    function testCannotChargeAnotherApprovedWallet() public {
        vm.prank(ALICE);
        token.approve(address(book), COST);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, COST)
        );
        vm.prank(BOB);
        book.sign("trying Alice's allowance");
        _assertUnchanged(ALICE, COST);
        assertEq(token.balanceOf(BOB), 1_000 ether);
    }

    function testExactApprovalCannotBeReused() public {
        _sign(ALICE, "paid");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(book), 0, COST)
        );
        vm.prank(ALICE);
        book.sign("unpaid duplicate");
        assertEq(book.entryCount(), 1);
        assertEq(book.getEntry(0).message, "paid");
        assertEq(token.totalSupply(), SUPPLY - COST);
    }

    function testPaginationNewestFirstAndStableDuringAppends() public {
        _sign(ALICE, "first");
        _sign(BOB, "second");
        _sign(ALICE, "third");
        (Guestbook.Entry[] memory page, uint256 next) = book.getEntries(book.entryCount(), 2);
        assertEq(page.length, 2);
        assertEq(page[0].message, "third");
        assertEq(page[1].message, "second");
        assertEq(page[1].signer, BOB);
        assertEq(next, 1);

        _sign(BOB, "arrived between pages");
        (page, next) = book.getEntries(next, 2);
        assertEq(page.length, 1);
        assertEq(page[0].message, "first");
        assertEq(next, 0);
        (page, next) = book.getEntries(next, 2);
        assertEq(page.length, 0);
        assertEq(next, 0);
        assertEq(book.entryCount(), 4);
    }

    function testEmptyBookPage() public view {
        (Guestbook.Entry[] memory page, uint256 next) = book.getEntries(0, 50);
        assertEq(page.length, 0);
        assertEq(next, 0);
    }

    function testInvalidReadArgumentsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(Guestbook.EntryNotFound.selector, 0));
        book.getEntry(0);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidCursor.selector, 1, 0));
        book.getEntries(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidPageSize.selector, 0));
        book.getEntries(0, 0);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidPageSize.selector, 51));
        book.getEntries(0, 51);
        vm.expectRevert(abi.encodeWithSelector(Guestbook.InvalidPageSize.selector, type(uint256).max));
        book.getEntries(0, type(uint256).max);
    }

    function testRejectsETHAndPayableSigning() public {
        vm.deal(ALICE, 2 ether);
        vm.startPrank(ALICE);
        token.approve(address(book), COST);
        (bool plainSend,) = address(book).call{value: 1 ether}("");
        (bool payableSign,) = address(book).call{value: 1 ether}(abi.encodeCall(book.sign, ("paid in ETH")));
        vm.stopPrank();
        assertFalse(plainSend);
        assertFalse(payableSign);
        _assertUnchanged(ALICE, COST);
        assertEq(address(book).balance, 0);
    }

    function testFuzzMessagesRespectByteLimit(bytes memory message) public {
        vm.startPrank(ALICE);
        token.approve(address(book), COST);
        if (message.length > 280) {
            vm.expectRevert(abi.encodeWithSelector(Guestbook.MessageTooLong.selector, message.length));
            book.sign(string(message));
            _assertUnchanged(ALICE, COST);
        } else {
            book.sign(string(message));
            assertEq(bytes(book.getEntry(0).message), message);
            assertEq(token.balanceOf(ALICE), 990 ether);
            assertEq(token.totalSupply(), SUPPLY - COST);
        }
        vm.stopPrank();
    }

    function testFuzzPaginationHasNoMissingOrRepeatedEntries(uint8 countSeed, uint8 limitSeed) public {
        uint256 count = bound(uint256(countSeed), 1, 60);
        uint256 limit = bound(uint256(limitSeed), 1, 50);
        vm.startPrank(ALICE);
        token.approve(address(book), count * COST);
        for (uint256 i; i < count; ++i) {
            book.sign(vm.toString(i));
        }
        vm.stopPrank();
        uint256 cursor = count;
        uint256 seen;
        while (cursor != 0) {
            (Guestbook.Entry[] memory page, uint256 next) = book.getEntries(cursor, limit);
            assertLe(page.length, limit);
            for (uint256 i; i < page.length; ++i) {
                assertEq(page[i].message, vm.toString(count - 1 - seen));
                assertEq(page[i].signer, ALICE);
                ++seen;
            }
            assertEq(next, cursor - page.length);
            cursor = next;
        }
        assertEq(seen, count);
        assertEq(token.totalSupply(), SUPPLY - count * COST);
    }

    function _sign(address signer, string memory message) internal returns (uint256 id) {
        vm.startPrank(signer);
        token.approve(address(book), COST);
        id = book.sign(message);
        vm.stopPrank();
    }

    function _assertUnchanged(address signer, uint256 allowance) internal view {
        assertEq(book.entryCount(), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(signer), 1_000 ether);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.allowance(signer, address(book)), allowance);
    }
}

contract WrongDecimalsToken {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @dev A real burnable token with a malicious callback, used only to test atomicity and the guard.
contract CallbackToken is LaunchToken {
    Guestbook internal target;
    bool internal propagateFailure;
    bool public callbackBlocked;
    uint256 public completedBurns;

    function configure(Guestbook book, bool propagate) external {
        target = book;
        propagateFailure = propagate;
    }

    function burnFrom(address account, uint256 amount) public override {
        super.burnFrom(account, amount);
        ++completedBurns;
        if (propagateFailure) {
            target.sign("nested");
        } else {
            (bool ok, bytes memory reason) = address(target).call(abi.encodeCall(target.sign, ("nested")));
            callbackBlocked = !ok
                && keccak256(reason)
                    == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        }
    }
}

contract GuestbookReentrancyTest is Test {
    CallbackToken internal token;
    Guestbook internal book;

    function setUp() public {
        token = new CallbackToken();
        book = new Guestbook(address(token));
        token.approve(address(book), 20 ether);
    }

    function testReentrantSignIsBlockedWhileOuterBurnSucceeds() public {
        token.configure(book, false);
        book.sign("outer");
        assertTrue(token.callbackBlocked());
        assertEq(token.completedBurns(), 1);
        assertEq(book.entryCount(), 1);
        assertEq(book.getEntry(0).signer, address(this));
        assertEq(book.getEntry(0).message, "outer");
        assertEq(token.totalSupply(), 1e27 - 10 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 10 ether);
        assertEq(token.allowance(address(this), address(book)), 10 ether);
    }

    function testPropagatedCallbackFailureRollsBackBurnEntryAndAllowance() public {
        token.configure(book, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        book.sign("rolled back");
        assertEq(book.entryCount(), 0);
        assertEq(token.completedBurns(), 0);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.allowance(address(this), address(book)), 20 ether);

        token.configure(book, false);
        assertEq(book.sign("retry"), 0);
        assertEq(token.completedBurns(), 1);
    }
}
