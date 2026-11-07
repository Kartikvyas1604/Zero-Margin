// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IClearingMarginEngine} from "./interfaces/IClearingMarginEngine.sol";

/// @title PortfolioMarginHook — a real Uniswap v4 hook enforcing post-withdrawal margin.
/// @notice Implements IHooks directly against v4-core: only `beforeRemoveLiquidity`
/// and `afterSwap` are enabled, so the mined address's low 14 bits equal 0x240.
/// Stateless: the guard reads the engine, the mark price flows through the
/// engine, and no call gets past `msg.sender == POOL_MANAGER` checks.
/// The guarded pool id is NOT baked into the mined address: with the id in the
/// constructor the pool's own id (keccak of a PoolKey that includes the hook)
/// would be a circular dependency. So the address is mined against a
/// placeholder id and the deploy script binds the real one once, before
/// renouncing ownership — mirroring the setEngine pattern.
contract PortfolioMarginHook is IHooks {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;
    IClearingMarginEngine public ENGINE;
    /// token0/token1 ordering: the volatile leg (WETH-ish) at deploy time.
    address public immutable VOLATILE_TOKEN;

    PoolId private _poolId;
    bool public poolSet;
    bool public engineSet;

    uint256 internal constant Q96 = 2 ** 96;
    uint64 internal constant MIN_MARK_PRICE_USDC = 1e6;
    uint64 internal constant MAX_MARK_PRICE_USDC = 1_000_000e6;

    address public owner;

    error EngineAlreadySet(address engine);
    error PoolAlreadySet(bytes32 current);
    error NotOwner(address caller);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// One-time engine binding so the hook can be mined ahead of the app
    /// (CREATE2 with the engine's address baked in would be circular).
    function setEngine(IClearingMarginEngine engine_) external onlyOwner {
        if (address(engine_) == address(0)) revert ZeroAddress();
        if (engineSet) revert EngineAlreadySet(address(ENGINE));
        ENGINE = engine_;
        engineSet = true;
    }

    /// One-time pool binding: call after `PoolManager.initialize(key, sqrtP)`
    /// with `poolId_ = keccak(abi.encode(key))` where key.hooks == this address.
    function setPoolId(bytes32 poolId_) external onlyOwner {
        if (poolSet) revert PoolAlreadySet(PoolId.unwrap(POOL_ID()));
        if (poolId_ == bytes32(0)) revert ZeroAddress();
        _poolId = PoolId.wrap(poolId_);
        poolSet = true;
    }

    function POOL_ID() public view returns (PoolId) {
        return _poolId;
    }

    function renounceOwnership() external onlyOwner {
        owner = address(0);
    }

    error ZeroAddress();
    error SpanMarginBreach(address trader, uint256 postWithdrawalEquityUsdc, uint256 requiredInitialMarginUsdc);
    error InvalidHookData();
    error NotPoolManager(address caller);
    error WrongPool();
    error InvalidLiquidityDelta();
    error PriceOutOfBounds(uint64 price);

    constructor(IPoolManager manager, bytes32 /* poolId baked for mined args, ignored */, address volatileToken, address owner_) {
        owner = owner_; // CREATE2-deploys wire through the universal factory,
        // whose msg.sender is not the operator; the owner is explicit here
        POOL_MANAGER = manager;
        VOLATILE_TOKEN = volatileToken;
        // _poolId is zero until setPoolId binds the real, post-mining id
    }

    // ── guard ──────────────────────────────────────────────────────
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        _onlyPoolManager();
        if (PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(POOL_ID())) revert WrongPool();
        if (params.liquidityDelta >= 0 || params.liquidityDelta == type(int256).min) revert InvalidLiquidityDelta();

        // Never trust hookData for the trader unless it is exactly the
        // 20-byte address equal to the sender (§4.11).
        address trader = sender;
        if (hookData.length != 0) {
            if (hookData.length != 20) revert InvalidHookData();
            if (address(bytes20(hookData)) != sender) revert InvalidHookData();
        }

        (uint256 amount0, uint256 amount1) = _removedAmounts(params);
        uint256 spotUsdc = _spotPriceUsdc();
        uint64 entry = ENGINE.bookEntryPrice(trader);
        uint256 wethPriceUsdc = spotUsdc > entry ? spotUsdc : entry;

        bool volatileIsToken0 = Currency.unwrap(poolKey.currency0) == VOLATILE_TOKEN;
        uint256 withdrawnUsd;
        if (volatileIsToken0) {
            withdrawnUsd = (amount0 * wethPriceUsdc) / 1e18 + amount1;
        } else {
            withdrawnUsd = amount0 + (amount1 * wethPriceUsdc) / 1e18;
        }

        (uint256 postEquity, uint256 requiredIM, bool active) = ENGINE.previewEquityAfterWithdrawal(trader, withdrawnUsd);
        if (active && postEquity < requiredIM) {
            revert SpanMarginBreach(trader, postEquity, requiredIM);
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // ── mark price ──────────────────────────────────────────────────
    function afterSwap(address, PoolKey calldata poolKey, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _onlyPoolManager();
        if (PoolId.unwrap(poolKey.toId()) == PoolId.unwrap(POOL_ID())) {
            uint64 price = _spotPriceUsdc();
            ENGINE.updateMarkPrice(PoolId.unwrap(POOL_ID()), price);
        }
        return (IHooks.afterSwap.selector, 0);
    }

    // Unsupported permissions revert loudly; the flag mask keeps them off
    // the mined address so the pool manager never calls them.
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert("unsupported");
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("unsupported");
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        revert("unsupported");
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        revert("unsupported");
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        returns (bytes4, BalanceDelta)
    {
        revert("unsupported");
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert("unsupported");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        revert("unsupported");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        revert("unsupported");
    }

    // ── internals ──────────────────────────────────────────────────

    function _onlyPoolManager() internal view {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager(msg.sender);
    }

    /// Canonical v4 withdrawal amounts for the burn: the branch follows the
    /// live price. Below the range the whole position is currency0; in range
    /// it splits at the live price; above it is currency1. The old shape
    /// ( treating every burn as price-below-range ) overcharged in-range
    /// positions by sqrtB/sqrtC — a factor of ~10^15 on the demo pool — so
    /// every removal looked like a total exit. This now equals the pool's
    /// own settlement math exactly (PortfolioMarginHook §4.10, corrected).
    function _removedAmounts(IPoolManager.ModifyLiquidityParams calldata params)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = uint128(uint256(-(params.liquidityDelta + 1)) + 1); // min-safe negate
        (uint160 sqrtCurrent, , , ) = POOL_MANAGER.getSlot0(POOL_ID());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(params.tickUpper);
        if (sqrtLower > sqrtUpper) (sqrtLower, sqrtUpper) = (sqrtUpper, sqrtLower);

        if (sqrtCurrent <= sqrtLower) {
            // below the range: entirely currency0
            uint256 den = FullMath.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), Q96);
            amount0 = FullMath.mulDiv(uint256(liquidity), sqrtUpper - sqrtLower, den);
            amount1 = 0;
        } else if (sqrtCurrent < sqrtUpper) {
            // in range: currency0 funds [livePrice .. upper], currency1 [lower .. livePrice]
            uint256 denUpper = FullMath.mulDiv(uint256(sqrtUpper), uint256(sqrtCurrent), Q96);
            amount0 = FullMath.mulDiv(uint256(liquidity), sqrtUpper - sqrtCurrent, denUpper);
            amount1 = FullMath.mulDiv(uint256(liquidity), sqrtCurrent - sqrtLower, Q96);
        } else {
            // above the range: entirely currency1
            amount0 = 0;
            amount1 = FullMath.mulDiv(uint256(liquidity), sqrtUpper - sqrtLower, Q96);
        }
    }

    /// USDC per WETH with 6 decimals from sqrtP (§4.10): (sqrtP² × 1e18) / 2^192.
    function _spotPriceUsdc() internal view returns (uint64 price) {
        (uint160 sqrtP, , , ) = POOL_MANAGER.getSlot0(POOL_ID());
        uint256 raw = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
        if (raw < MIN_MARK_PRICE_USDC || raw > MAX_MARK_PRICE_USDC) revert PriceOutOfBounds(uint64(raw));
        price = uint64(raw);
    }
}
