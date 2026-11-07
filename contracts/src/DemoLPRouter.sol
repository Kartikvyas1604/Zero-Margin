// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "./interfaces/IAqua.sol";

interface IClearingAquaApp {
    function openBook(uint128 lpNotionalUsdc, uint128 shortNotionalUsdc, uint128 postedMarginUsdc, bytes32 aquaStrategyHash)
        external;
    function unwind(address trader, int256 priceShockBps) external;
}

/// @title DemoLPRouter — the demo trader's pool harness.
/// @notice In Uniswap v4, PoolManager calls must come from a contract that
/// implements `unlockCallback` — an EOA cannot call modifyLiquidity directly.
/// This router IS the demo trader: the ClearingAquaApp book is keyed on
/// books[msg.sender] == this router, and the guard's `sender` is this router,
/// so one address plays every role the cross-margin engine checks. The owner
/// (the demo burner key) relays ops. The router holds the LP position and the
/// shipped margin; it introduces no trust assumptions — the guard still reads
/// its decision from the engine, and the router only ever moves its own funds.
contract DemoLPRouter is IUnlockCallback {
    IPoolManager public immutable MANAGER;
    address public immutable OWNER;

    /// Full-range ticks for the demo pool: fee 500 pairs with tickSpacing 10,
    /// and ±887,270 are multiples of 10. A different spacing needs different
    /// ticks (initialize/TickMath would revert loudly, not silently).
    int24 internal constant FULL_RANGE_LOWER = -887270;
    int24 internal constant FULL_RANGE_UPPER = 887270;

    IAqua public AQUA;
    IERC20 public USDC;
    IClearingAquaApp public APP;
    PoolKey internal _pool;
    bool internal _poolSet;

    bool internal _aquaSet;
    bool internal _usdcSet;
    bool internal _appSet;

    event AppBound(address indexed app);
    event PoolBound(address currency0, address currency1, uint24 fee, int24 tickSpacing);
    event Opened(address indexed trader, uint128 lp, uint128 short, uint128 posted, bytes32 strategy);
    event AddLP(uint128 liquidity, int256 amount0, int256 amount1);
    event RemoveLP(uint128 liquidity, uint256 amount0Out, uint256 amount1Out);
    event Swapped(bool zeroForOne, int256 amountSpecified, int256 amount0, int256 amount1);

    error AlreadySet();
    error NotOwner(address caller);
    error WrongCaller(address caller);
    error UnknownOp(uint8 op);
    error SlippageBreached(uint256 got, uint256 min);

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        _;
    }

    constructor(IPoolManager manager, address owner_) {
        MANAGER = manager;
        OWNER = owner_;
    }

    // ── one-time configuration ─────────────────────────────────────

    function setAqua(IAqua aqua_) external onlyOwner {
        if (_aquaSet) revert AlreadySet();
        AQUA = aqua_;
        _aquaSet = true;
    }

    function setUsdc(IERC20 usdc_) external onlyOwner {
        if (_usdcSet && address(usdc_) != address(0)) revert AlreadySet();
        USDC = usdc_;
        _usdcSet = true;
    }

    function setApp(IClearingAquaApp app_) external onlyOwner {
        if (_appSet) revert AlreadySet();
        APP = app_;
        _appSet = true;
        emit AppBound(address(app_));
    }

    /// The demo pool key — set after the pool initializes, once, forever.
    function setPool(PoolKey memory key_) external onlyOwner {
        if (_poolSet) revert AlreadySet();
        _pool = key_;
        _poolSet = true;
        emit PoolBound(Currency.unwrap(key_.currency0), Currency.unwrap(key_.currency1), key_.fee, key_.tickSpacing);
    }

    /// Approvals for the whole lifecycle: aqua (ship margin), pool tokens (pay
    /// in), both idempotent OneApproves for the demo.
    function approveAll() external onlyOwner {
        IERC20(address(USDC)).approve(address(AQUA), type(uint256).max);
        IERC20(Currency.unwrap(_pool.currency0)).approve(address(MANAGER), type(uint256).max);
        IERC20(Currency.unwrap(_pool.currency1)).approve(address(MANAGER), type(uint256).max);
    }

    // ── trader relays (the cross-margin engine sees this address) ─────

    /// Owns the book — books[msg.sender] == this router; ships the margin.
    function openBook(uint128 lpNotionalUsdc, uint128 shortNotionalUsdc, uint128 postedMarginUsdc, bytes32 strategyHash)
        external
        onlyOwner
    {
        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = postedMarginUsdc;
        AQUA.ship(address(APP), strategyHash, tokens, amounts);
        APP.openBook(lpNotionalUsdc, shortNotionalUsdc, postedMarginUsdc, strategyHash);
        emit Opened(address(this), lpNotionalUsdc, shortNotionalUsdc, postedMarginUsdc, strategyHash);
    }

    /// Realizes the hedge gain into the router's virtual balance and settles
    /// the LP loss, exactly like the terminal's UNWIND-01 story.
    function unwind(int256 priceShockBps) external onlyOwner {
        APP.unwind(address(this), priceShockBps);
    }

    // ── pool ops (routed through the manager's lock) ─────────────────
    /// ADD: pays both debts from the router's own balance after modify.
    function addLP(uint128 liquidity) external onlyOwner {
        bytes memory result = MANAGER.unlock(abi.encode(uint8(1), abi.encode(liquidity)));
        (int256 a0, int256 a1) = abi.decode(result, (int256, int256));
        emit AddLP(liquidity, a0, a1);
    }

    /// REMOVE: takes credits out to the router; optional slippage bound on the
    /// USDC leg. Ernest_margin: the PortfolioMarginHook guard decides.
    function removeLP(uint128 liquidity, uint256 minUsdcOut) external onlyOwner {
        bytes memory result = MANAGER.unlock(abi.encode(uint8(2), abi.encode(liquidity, minUsdcOut)));
        (uint256 a0, uint256 a1) = abi.decode(result, (uint256, uint256));
        emit RemoveLP(liquidity, a0, a1);
    }

    /// A small swap once, so `afterSwap` pushes the real mark price while the
    /// demo runs (out of the router's own balance, nothing else passes it).
    function swap(bool zeroForOne, int256 amountSpecified, uint160 limit) external onlyOwner {
        bytes memory result = MANAGER.unlock(abi.encode(uint8(3), abi.encode(zeroForOne, amountSpecified, limit)));
        (int256 a0, int256 a1) = abi.decode(result, (int256, int256));
        emit Swapped(zeroForOne, amountSpecified, a0, a1);
    }

    // ── manager callback ─────────────────────────────────────────────
    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        if (msg.sender != address(MANAGER)) revert WrongCaller(msg.sender);
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (op == 1) {
            (uint128 liquidity) = abi.decode(payload, (uint128));
            (BalanceDelta delta,) = MANAGER.modifyLiquidity(
                _pool,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: FULL_RANGE_LOWER,
                    tickUpper: FULL_RANGE_UPPER,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                abi.encodePacked(address(this)) // hookData == sender, exactly 20 bytes (§4.11)
            );
            int128 a0 = delta.amount0();
            int128 a1 = delta.amount1();
            if (a0 < 0) _pay(_pool.currency0, uint128(-a0));
            if (a1 < 0) _pay(_pool.currency1, uint128(-a1));
            return abi.encode(int256(a0), int256(a1));
        }

        if (op == 2) {
            (uint128 liquidity, uint256 minUsdcOut) = abi.decode(payload, (uint128, uint256));
            (BalanceDelta delta,) = MANAGER.modifyLiquidity(
                _pool,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: FULL_RANGE_LOWER,
                    tickUpper: FULL_RANGE_UPPER,
                    // min-safe negation; the hook reverts before the pool moves
                    liquidityDelta: -int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                abi.encodePacked(address(this)) // hookData == sender, exactly 20 bytes (§4.11)
            );
            int128 a0 = delta.amount0();
            int128 a1 = delta.amount1();
            uint256 out0;
            uint256 out1;
            if (a0 > 0) {
                out0 = uint256(uint128(a0));
                MANAGER.take(_pool.currency0, address(this), out0);
            }
            if (a1 > 0) {
                out1 = uint256(uint128(a1));
                MANAGER.take(_pool.currency1, address(this), out1);
            }
            if (out1 < minUsdcOut) revert SlippageBreached(uint256(uint128(a1)), minUsdcOut);
            return abi.encode(out0, out1);
        }

        if (op == 3) {
            (bool zeroForOne, int256 amountSpecified, uint160 limit) = abi.decode(payload, (bool, int256, uint160));
            BalanceDelta delta = MANAGER.swap(
                _pool,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: limit
                }),
                abi.encode(address(this))
            );
            int128 a0 = delta.amount0();
            int128 a1 = delta.amount1();
            if (a0 < 0) _pay(_pool.currency0, uint128(-a0));
            else if (a0 > 0) MANAGER.take(_pool.currency0, address(this), uint256(uint128(a0)));
            if (a1 < 0) _pay(_pool.currency1, uint128(-a1));
            else if (a1 > 0) MANAGER.take(_pool.currency1, address(this), uint256(uint128(a1)));
            return abi.encode(int256(a0), int256(a1));
        }

        revert UnknownOp(op);
    }

    /// canonical v4 payment for a pool debt: sync → transfer → settle.
    function _pay(Currency currency, uint128 debt) internal {
        MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).transfer(address(MANAGER), debt);
        MANAGER.settle();
    }
}
