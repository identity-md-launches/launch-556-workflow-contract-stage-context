// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guestbook} from "../src/Guestbook.sol";

/// @dev Models constructor callers and static arguments; does not replace the protocol factory.
contract ConstructorHarness {
    function deploy() external returns (LaunchToken token, Guestbook book) {
        token = new LaunchToken{salt: bytes32(uint256(1))}();
        book = new Guestbook{salt: bytes32(uint256(2))}(address(token));
    }
}

contract DeploymentTest is Test {
    function testFactoryConstructionPreservesWholeSupplyAndNeedsNoInitialization() public {
        ConstructorHarness factory = new ConstructorHarness();
        (LaunchToken token, Guestbook book) = factory.deploy();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(address(book.token()), address(token));
        assertEq(book.entryCount(), 0);
        _assertRuntime(address(token));
        _assertRuntime(address(book));
    }

    function _assertRuntime(address target) internal view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden opcode");
        }
    }
}
