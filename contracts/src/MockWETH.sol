// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20 as OZERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockWETH — the volatile leg of the demo pool (18 decimals).
/// @notice A plain mintable ERC-20 stand-in for WETH so the pool math keeps
/// the canonical 6/18-decimal fold the hook's USD conversion assumes.
/// Owner-restricted mint: the deploy script mints the LP seed to the router.
contract MockWETH is OZERC20 {
    address public immutable MINT_AUTHORITY;

    constructor(address mintAuthority_) OZERC20("Wrapped Ether (demo)", "WETH.d") {
        MINT_AUTHORITY = mintAuthority_;
        _mint(msg.sender, 100_000e18);
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == MINT_AUTHORITY, "mint: not authority");
        _mint(to, amount);
    }
}
