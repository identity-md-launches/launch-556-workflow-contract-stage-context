// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "./LaunchToken.sol";

/// @notice An immutable, append-only guestbook. Each signature destroys ten launch tokens.
/// @dev Configure only with this project's LaunchToken. There are no administrative powers.
contract Guestbook is ReentrancyGuard {
    uint256 public constant SIGNING_COST = 10 * 10 ** 18;
    uint256 public constant MAX_MESSAGE_BYTES = 280;
    uint256 public constant MAX_PAGE_SIZE = 50;

    LaunchToken public immutable token;

    struct Entry {
        address signer;
        uint256 timestamp;
        string message;
    }

    Entry[] private _entries;

    error InvalidToken(address tokenAddress);
    error InvalidTokenDecimals(uint8 decimals);
    error MessageTooLong(uint256 length);
    error EntryNotFound(uint256 entryId);
    error InvalidCursor(uint256 beforeId, uint256 count);
    error InvalidPageSize(uint256 limit);

    event Signed(uint256 indexed entryId, address indexed signer, uint256 timestamp, string message);

    /// @param tokenAddress Address of the already deployed LaunchToken ($token in the manifest).
    /// @dev Nonpayable; does not move any tokens or grant authority to its deployer.
    constructor(address tokenAddress) {
        if (tokenAddress.code.length == 0) revert InvalidToken(tokenAddress);
        LaunchToken configuredToken = LaunchToken(tokenAddress);
        uint8 decimals = configuredToken.decimals();
        if (decimals != 18) revert InvalidTokenDecimals(decimals);
        token = configuredToken;
    }

    /// @notice Append a message after approving this contract for SIGNING_COST tokens.
    /// @dev Length is in bytes. Empty and repeated messages are allowed and charged normally.
    ///      Only msg.sender can be charged. Any failed burn rolls the entire entry back.
    /// @return entryId The new entry's zero-based, permanent identifier.
    function sign(string calldata message) external nonReentrant returns (uint256 entryId) {
        uint256 length = bytes(message).length;
        if (length > MAX_MESSAGE_BYTES) revert MessageTooLong(length);

        entryId = _entries.length;
        _entries.push(Entry({signer: msg.sender, timestamp: block.timestamp, message: message}));
        emit Signed(entryId, msg.sender, block.timestamp, message);
        token.burnFrom(msg.sender, SIGNING_COST);
    }

    function entryCount() external view returns (uint256) {
        return _entries.length;
    }

    function getEntry(uint256 entryId) external view returns (Entry memory) {
        if (entryId >= _entries.length) revert EntryNotFound(entryId);
        return _entries[entryId];
    }

    /// @notice Read newest first, starting strictly below beforeId. Start with entryCount().
    /// @dev Use nextBeforeId for the next page; zero means the snapshot has been exhausted.
    ///      Entry IDs in a page are beforeId - 1 - i. New signatures do not shift earlier IDs.
    /// @param beforeId Exclusive upper bound, at most entryCount().
    /// @param limit Number of entries requested, from 1 through MAX_PAGE_SIZE.
    function getEntries(uint256 beforeId, uint256 limit)
        external
        view
        returns (Entry[] memory entries, uint256 nextBeforeId)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageSize(limit);
        uint256 count = _entries.length;
        if (beforeId > count) revert InvalidCursor(beforeId, count);

        uint256 size = beforeId < limit ? beforeId : limit;
        entries = new Entry[](size);
        for (uint256 i; i < size; ++i) {
            entries[i] = _entries[beforeId - 1 - i];
        }
        nextBeforeId = beforeId - size;
    }
}
