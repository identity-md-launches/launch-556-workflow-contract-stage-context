// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @notice Guestbook's token: one fixed issuance, plain transfers, and voluntary burns.
/// @dev The deploying factory receives the entire issuance. No post-construction mint path exists.
///      Explicit burns reduce totalSupply; ordinary transfers never burn or charge a fee.
contract LaunchToken is ERC20Burnable {
    constructor() ERC20("Guestbook", "GUEST") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
