// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    uint256 internal constant SUPPLY = 1e27;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testInitialSupplyAndMetadata() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "Guestbook");
        assertEq(token.symbol(), "GUEST");
    }

    function testTransferEmitsEventAndHasNoFee() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 10 ether);
        assertTrue(token.transfer(ALICE, 10 ether));
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testZeroAndSelfTransfersPreserveSupply() public {
        assertTrue(token.transfer(ALICE, 0));
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testApprovalAndDelegatedTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 12 ether);
        assertTrue(token.approve(ALICE, 12 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 10 ether));
        assertEq(token.allowance(address(this), ALICE), 2 ether);
        assertEq(token.balanceOf(BOB), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInsufficientBalanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInsufficientAllowanceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testZeroRecipientAndSpenderRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testHolderBurnReducesSupply() public {
        token.transfer(ALICE, 20 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, address(0), 10 ether);
        vm.prank(ALICE);
        token.burn(10 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
    }

    function testAuthorizedBurnConsumesAllowance() public {
        token.approve(ALICE, 20 ether);
        vm.prank(ALICE);
        token.burnFrom(address(this), 10 ether);
        assertEq(token.allowance(address(this), ALICE), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10 ether);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
    }

    function testUnauthorizedBurnReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 10 ether));
        vm.prank(ALICE);
        token.burnFrom(address(this), 10 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testRevertingBurnRestoresAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10 ether));
        vm.prank(BOB);
        token.burnFrom(ALICE, 10 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInfiniteAllowanceFollowsERC20Semantics() public {
        token.approve(ALICE, type(uint256).max);
        vm.startPrank(ALICE);
        token.burnFrom(address(this), 10 ether);
        token.transferFrom(address(this), BOB, 10 ether);
        vm.stopPrank();
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY - 10 ether);
        assertEq(token.balanceOf(BOB), 10 ether);
    }

    function testNoMintOwnerPauseOrUpgradeEntrypoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerOK,) = address(token).call(data);
            assertFalse(deployerOK);
            vm.prank(ALICE);
            (bool outsiderOK,) = address(token).call(data);
            assertFalse(outsiderOK);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzzTransferAndBurnConserveTokens(uint256 moved, uint256 burned) public {
        moved = bound(moved, 0, SUPPLY);
        burned = bound(burned, 0, moved);
        token.transfer(ALICE, moved);
        vm.prank(ALICE);
        token.burn(burned);
        assertEq(token.balanceOf(ALICE), moved - burned);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE), token.totalSupply());
        assertEq(token.totalSupply() + burned, SUPPLY);
    }
}
