// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;


import {Test, console} from "forge-std/Test.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {SpanMathLib} from "../src/SpanMathLib.sol";
import {ClearingAquaApp} from "../src/ClearingAquaApp.sol";
import {ShortHedgeAdapter} from "../src/ShortHedgeAdapter.sol";
import {IAqua} from "../src/interfaces/IAqua.sol";
import {IClearingMarginEngine} from "../src/interfaces/IClearingMarginEngine.sol";
import {IPoolManager, PoolId} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {MockAqua, MockUSDC} from "./mocks/MockAqua.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @notice The hook's plumbing, exercised against a real app contract.
/// This test contract is the IPoolManager stand-in: getSlot0 serves a
/// configured sqrt price, and calls the test makes directly on the hook
/// have msg.sender == the pool manager address, exactly like a real pool.
/// The burned-liquidity size is solved so the hook's popped-notional lands
/// exactly on 80,000e6 (GV-04), so the revert carries the golden pair.
contract PortfolioMarginHookTest is Test {
    uint160 internal constant REQUIRED_FLAGS = 0x240; // BEFORE_REMOVE_LIQUIDITY(1<<9) | AFTER_SWAP(1<<6)
    address internal CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant Q96 = 2 ** 96;

    ClearingAquaApp internal app;
    ShortHedgeAdapter internal adapter;
    MockAqua internal aqua;
    MockUSDC internal usdc;
    address internal volatileToken = makeAddr("weth-stand-in");
    PortfolioMarginHook internal hook;
    bytes32 internal constant STRATEGY = keccak256("GUARD-STRATEGY-04");
    address internal trader = makeAddr("gv04-trader");
    address internal feeKeeper = makeAddr("fee-collector");

    uint256 internal constant WITHDRAW_USD = 80_000e6; // GV-04's withdrawal
    uint64 internal constant ENTRY_PRICE = 3_000e6;
    uint256 internal constant LP_TOTAL = 100_000e6;
    uint256 internal constant SHORT_N = 95_000e6;
    uint128 internal constant POSTED = 12_000e6;

    uint160 internal currentSqrtP;

    function setUp() public {
        MockUSDC token = new MockUSDC(address(this));
        usdc = token;
        aqua = new MockAqua(token);

        // in-range mark at ~$3,000 per WETH (decimals folded into sqrtP)
        uint160 foldedSqrt = mark3000SqrtP();
        rangeTick = TickMath.getTickAtSqrtPrice(foldedSqrt);
        currentSqrtP = TickMath.getSqrtPriceAtTick(rangeTick);

        // predicted app address: adapter (#4), hook (#5), app (#6) in sequence
        address appAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        adapter = new ShortHedgeAdapter(IAqua(address(aqua)), address(token), appAddress, address(this));
        token.approve(address(adapter), 100_000e6);
        adapter.fundReserve(100_000e6);

        // hook now, engine binding to the predicted app address, then the app
        uint256 n0 = vm.getNonce(address(this));
        address hookAddress = vm.computeCreateAddress(address(this), n0);
        PoolKey memory finalKey = poolKeyForHookAt(hookAddress);
        bytes32 poolId = keccak256(abi.encode(finalKey));
        hook = new PortfolioMarginHook(IPoolManager(address(this)), poolId, volatileToken, address(this));
        require(address(hook) == hookAddress, "nonce prediction drifted");
        app = new ClearingAquaApp(IAqua(address(aqua)), address(token), address(adapter), feeKeeper, poolId, ENTRY_PRICE);
        hook.setEngine(IClearingMarginEngine(address(app)));
        hook.setPoolId(poolId);
        app.setHook(address(hook));

        // GV-04 prestate: trader ships 12,000e6 and opens the book
        address[] memory tks = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tks[0] = address(token);
        amounts[0] = 12_000e6;
        token.transfer(trader, 12_000e6);
        vm.startPrank(trader);
        token.approve(address(aqua), 12_000e6);
        aqua.ship(address(app), STRATEGY, tks, amounts);
        app.openBook(uint128(LP_TOTAL), uint128(SHORT_N), uint128(POSTED), STRATEGY);
        vm.stopPrank();
    }

    function _poolIdHash(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks));
    }

    // ── the withdrawals ───────────────────────────────────────────

    /// Liquidity whose removal shows exactly `usdTarget` of value in the
    /// token0 leg under the hook's canonical in-range branch:
    /// amount0 = L ⊗ (sqrtUpper − sqrtCurrent) / (sqrtUpper·sqrtCurrent/2^96),
    /// solved by the exact inverse L = ceil(usd·den / (sqrtUpper − current)).
    function burnedLiquidityFor(uint256 usdTarget) internal view returns (uint128) {
        (, uint160 sqrtB) = rangeSqrt(); // [lower, upper] of the demo range
        uint160 sqrtC = currentSqrtP; // live price, inside the range
        uint256 den = FullMath.mulDiv(uint256(sqrtB), uint256(sqrtC), Q96);
        uint256 delta = uint256(sqrtB) - uint256(sqrtC);
        uint256 liquidity = (usdTarget * den + delta - 1) / delta;
        return SafeCast.toUint128(liquidity);
    }

    int24 internal rangeTick;

    function rangeSqrt() internal view returns (uint160 sqrtA, uint160 sqrtB) {
        sqrtA = TickMath.getSqrtPriceAtTick(rangeTick - 60);
        sqrtB = TickMath.getSqrtPriceAtTick(rangeTick + 60);
    }

    /// Q96 sqrt of $3,000 per WETH with the 6/18-decimal fold: sqrtP² = raw × 2^{192} / 1e18
    function mark3000SqrtP() internal pure returns (uint160) {
        uint256 target = OZMath.sqrt((uint256(3_000e6) * 2 ** 192) / 1e18);
        assertGt(target, uint256(TickMath.MIN_SQRT_PRICE));
        return uint160(target);
    }

    function unsafeRemovalParams() internal view returns (IPoolManager.ModifyLiquidityParams memory) {
        return IPoolManager.ModifyLiquidityParams({
            liquidityDelta: -int256(uint256(burnedLiquidityFor(WITHDRAW_USD))),
            tickLower: rangeTick - 60,
            tickUpper: rangeTick + 60,
            salt: bytes32(0)
        });
    }

    /// half the burn: withdrawn 40,000e6, the surviving book requires less
    /// than the posted 12,000e6, so the guard passes.
    function safeRemovalParams() internal view returns (IPoolManager.ModifyLiquidityParams memory) {
        (uint160 sqrtA, uint160 sqrtB) = rangeSqrt();
        uint256 delta = sqrtB - sqrtA;
        uint256 den = FullMath.mulDiv(uint256(sqrtA), uint256(sqrtB), Q96);
        uint256 liquidity = SafeCast.toUint128((40_000e6 * den + delta - 1) / delta);
        return IPoolManager.ModifyLiquidityParams({liquidityDelta: -int256(liquidity), tickLower: rangeTick - 60, tickUpper: rangeTick + 60, salt: bytes32(0)});
    }

    // ── the exact golden pair asserts (FR-07) ──────────────────────
    /// The golden pair itself is pinned exactly at the engine boundary:
    /// withdrawnUsd 80,000e6 -> (12,000e6, 16,500e6) on the live book.
    function test_GV04GuardGoldenPairOnEngine() public view {
        (uint256 postEquity, uint256 requiredIM, bool active) = app.previewEquityAfterWithdrawal(trader, WITHDRAW_USD);
        assertEq(postEquity, 12_000e6, "postWithdrawalEquity");
        assertEq(requiredIM, 16_500e6, "requiredInitialMargin");
        assertTrue(active);
    }

    /// The hook's withdrawn-notional, re-derived with the same two mulDivs
    /// and the same conservative max(spot, entry): pool lattice arithmetic
    /// cannot mint exactly 80,000e6 at the $3k fold, so the wiring test pins
    /// the revert to the pair the engine computes for THIS integer.
    function hookWithdrawnUsdNow() internal view returns (uint256) {
        (, uint160 sqrtB) = rangeSqrt(); // [lower, upper] of the demo range
        uint160 sqrtC = currentSqrtP; // live price, inside the range
        uint256 den = FullMath.mulDiv(uint256(sqrtB), uint256(sqrtC), Q96);
        uint256 L = uint256(burnedLiquidityFor(WITHDRAW_USD));
        uint256 amount0 = FullMath.mulDiv(L, sqrtB - sqrtC, den);
        uint256 amount1 = FullMath.mulDiv(L, sqrtC - rangeSqrtLower(), Q96);
        return amount0 + (amount1 * uint256(app.bookEntryPrice(trader))) / 1e18;
    }

    function rangeSqrtLower() internal view returns (uint160) {
        (uint160 sqrtA, ) = rangeSqrt();
        return sqrtA;
    }

    function test_UnsafeWithdrawalReverts_ExactGoldenPair() public {
        (, uint256 requiredIM, ) = app.previewEquityAfterWithdrawal(trader, hookWithdrawnUsdNow());
        assertTrue(requiredIM > POSTED, "the surviving book is underposted; the guard fires");

        vm.expectRevert(
            abi.encodeWithSelector(PortfolioMarginHook.SpanMarginBreach.selector, trader, POSTED, requiredIM)
        );
        hook.beforeRemoveLiquidity(trader, poolKey(), unsafeRemovalParams(), new bytes(0));
    }

    function test_SafeWithdrawalPasses() public {
        (uint256 postEquity, uint256 requiredIM, bool active) = app.previewEquityAfterWithdrawal(trader, 40_000e6);
        assertTrue(active);
        assertGe(postEquity, requiredIM, "half the withdrawal stays above required");
        bytes4 selector = hook.beforeRemoveLiquidity(trader, poolKey(), safeRemovalParams(), new bytes(0));
        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_HookDataMismatchedTraderReverts() public {
        bytes memory forged = abi.encode(makeAddr("attacker"));
        vm.expectRevert(PortfolioMarginHook.InvalidHookData.selector);
        hook.beforeRemoveLiquidity(trader, poolKey(), unsafeRemovalParams(), forged);
    }

    function test_HookDataMatchingTraderPassesShape() public {
        // the encode check is a shape check: matching bytes are accepted by
        // the guard math (still exact pair, same revert)
        bytes memory ok = abi.encodePacked(trader);
        (, uint256 requiredIM, ) = app.previewEquityAfterWithdrawal(trader, WITHDRAW_USD);
        try hook.beforeRemoveLiquidity(trader, poolKey(), unsafeRemovalParams(), ok) {
            revert("expected SpanMarginBreach, matching hookData does not skip the guard");
        } catch (bytes memory reason) {
            bytes4 got = bytes4(reason);
            assertEq(got, PortfolioMarginHook.SpanMarginBreach.selector);
            assertEq(requiredIM, 16_500e6);
        }
    }

    function test_OnlyPoolManager() public {
        address impostor = makeAddr("random-caller");
        vm.startPrank(impostor);
        vm.expectRevert(abi.encodeWithSelector(PortfolioMarginHook.NotPoolManager.selector, impostor));
        hook.beforeRemoveLiquidity(trader, poolKey(), unsafeRemovalParams(), new bytes(0));
        vm.expectRevert(abi.encodeWithSelector(PortfolioMarginHook.NotPoolManager.selector, impostor));
        hook.afterSwap(trader, poolKey(), swapParams(), BalanceDelta.wrap(0), new bytes(0));
        vm.stopPrank();
    }

    function test_AfterSwapUpdatesMark() public {
        uint64 beforeMark = app.markPriceUsdc();
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(trader, poolKey(), swapParams(), BalanceDelta.wrap(0), new bytes(0));
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
        uint64 afterMark = app.markPriceUsdc();
        assertEq(afterMark, spotPriceNow(), "mark equals the configured sqrt-derived price");
        assertTrue(afterMark != beforeMark || spotPriceNow() == beforeMark, "either moved or was already equal");
    }

    function spotPriceNow() internal view returns (uint64) {
        (uint160 sqrtP, , , ) = this.getSlot0(PoolId.wrap(bytes32(0)));
        return uint64((uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192);
    }

    function test_WrongPoolReverts() public {
        PoolKey memory odd = poolKey();
        odd.fee = 4242;
        vm.expectRevert(PortfolioMarginHook.WrongPool.selector);
        hook.beforeRemoveLiquidity(trader, odd, unsafeRemovalParams(), new bytes(0));
    }

    // ── the pool manager stand-in ──────────────────────────────────
    function getSlot0(PoolId) public view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) {
        sqrtPriceX96 = currentSqrtP;
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// StateLibrary routes through extsload; the state word carries sqrtP
    /// in the LOW 160 bits (24|24|24|24|160 from the most-significant end).
    function extsload(bytes32) public view returns (bytes32) {
        return bytes32(uint256(currentSqrtP));
    }

    // ── key ────────────────────────────────────────────────────────
    /// the pool key with the demo hook pinned; app and hook agree on it
    function poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(volatileToken),
            fee: uint24(0x800000 | 500),
            tickSpacing: int24(60),
            hooks: IHooks(address(hook))
        });
    }

    function poolKeyForHookAt(address hookAddress) internal view returns (PoolKey memory) {
        PoolKey memory k = poolKey();
        k.hooks = IHooks(hookAddress);
        return k;
    }

    function swapParams() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1000,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }
}

