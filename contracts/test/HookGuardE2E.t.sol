// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {ClearingAquaApp} from "../src/ClearingAquaApp.sol";
import {SpanMathLib} from "../src/SpanMathLib.sol";
import {ShortHedgeAdapter} from "../src/ShortHedgeAdapter.sol";
import {DemoLPRouter, IClearingAquaApp} from "../src/DemoLPRouter.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MockAqua} from "../src/MockAqua.sol";
import {IAqua} from "../src/interfaces/IAqua.sol";
import {IClearingMarginEngine} from "../src/interfaces/IClearingMarginEngine.sol";
import {MockUSDC} from "./mocks/MockAqua.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager, PoolId, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

/// @notice The end-to-end rehearsal of the demo's hook segment, against a
/// REAL Uniswap v4 PoolManager: a real pool (mined hook, real pool id),
/// DemoLPRouter as trader, the GV-01 book open, a seeded full-range position.
/// Two removal beats, exactly what the video shows:
///   1. a partial withdrawal — small enough to stay marginable — passes;
///   2. a full-position withdrawal (remaining LP → 0) reverts with
///      SpanMarginBreach carrying the engine's own required-im figure.
/// Plus a real swap that trains afterSwap to push the mark price.
contract HookGuardE2E is Test {
    uint160 internal constant REQUIRED_FLAGS = 0x240; // beforeRemoveLiquidity | afterSwap
    uint256 internal constant Q192 = 2 ** 192;
    bytes32 internal constant STRATEGY = keccak256("ZEROMARGIN-DEMO-STRATEGY");

    PoolManager internal manager;
    MockWETH internal weth;
    MockAqua internal aqua;
    ShortHedgeAdapter internal adapter;
    ClearingAquaApp internal app;
    DemoLPRouter internal router;
    PortfolioMarginHook internal hook;
    PoolKey internal key;
    bytes32 internal realPoolId;
    uint128 internal liquidity;
    uint160 internal sqrtP3000;
    address internal usdc;

    uint128 internal constant LP_TOTAL = 100_000e6;
    uint128 internal constant SHORT_N = 95_000e6;
    /// GV-04's golden posted amount: lean enough that removing the whole LP
    /// trips the guard (required-im rises as LP leaves the book), while the
    /// partial-removal beat stays comfortably marginable.
    uint128 internal constant POSTED = 12_000e6;

    function setUp() public {
        // deploy order (each plain `new` bumps the deployer nonce by one):
        // manager, weth, router, aqua, adapter, app — the app is the 5th
        // creation after startNonce. The mined USDC and hook go through the
        // CREATE2 factory (plain calls, no nonce), so the offset holds.
        uint256 startNonce = vm.getNonce(address(this));
        address appAddress = vm.computeCreateAddress(address(this), startNonce + 5);

        manager = new PoolManager(address(this));

        weth = new MockWETH(address(this));
        router = new DemoLPRouter(manager, address(this));

        (uint256 salt, address usdcAddr) = _mineUsdcAbove(address(weth));
        (bool ok, ) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(salt), type(MockUSDC).creationCode, abi.encode(address(this))));
        require(ok && usdcAddr == vm.computeCreate2Address(bytes32(salt), keccak256(abi.encodePacked(type(MockUSDC).creationCode, abi.encode(address(this)))), CREATE2_FACTORY), "mined USDC");
        usdc = usdcAddr;

        aqua = new MockAqua(IERC20(usdc));
        adapter = new ShortHedgeAdapter(IAqua(address(aqua)), usdc, appAddress, address(this));

        bytes32 placeholderId = keccak256("zeromargin.real-pool-placeholder");
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(
            CREATE2_FACTORY,
            REQUIRED_FLAGS,
            type(PortfolioMarginHook).creationCode,
            abi.encode(manager, placeholderId, address(weth), address(this))
        );
        (ok, ) = CREATE2_FACTORY.call(abi.encodePacked(hookSalt, type(PortfolioMarginHook).creationCode, abi.encode(manager, placeholderId, address(weth), address(this))));
        require(ok, "mined hook create failed");
        hook = PortfolioMarginHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(usdc),
            fee: uint24(500),
            tickSpacing: int24(10),
            hooks: IHooks(hookAddress)
        });
        realPoolId = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));

        require(appAddress == vm.computeCreateAddress(address(this), vm.getNonce(address(this))), "app nonce drifted");
        app = new ClearingAquaApp(IAqua(address(aqua)), usdc, address(adapter), address(this), realPoolId, 3_000e6);

        app.setHook(hookAddress);
        hook.setEngine(IClearingMarginEngine(address(app)));
        hook.setPoolId(realPoolId);
        router.setAqua(IAqua(address(aqua)));
        router.setUsdc(IERC20(usdc));
        router.setApp(IClearingAquaApp(address(app)));
        router.setPool(key);
        router.approveAll();
        app.renounceOwnership();
        hook.renounceOwnership();

        // funding: LP seed + pay-in stock to the router; the hedge reserve.
        // the addLP consumes ~20 WETH + the full 60k USDC on top of the 25k ship
        MockUSDC(usdc).transfer(address(router), 100_000e6);
        weth.transfer(address(router), 30e18);
        MockUSDC(usdc).approve(address(adapter), 100_000e6);
        adapter.fundReserve(100_000e6);

        sqrtP3000 = uint160(OZMath.sqrt((uint256(3_000e6) * Q192) / 1e18));
        manager.initialize(key, sqrtP3000);

        router.openBook(LP_TOTAL, SHORT_N, POSTED, STRATEGY);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP3000,
            TickMath.MIN_SQRT_PRICE + 1,
            TickMath.MAX_SQRT_PRICE - 1,
            uint256(20e18),
            uint256(60_000e6)
        );
        require(liquidity > 0);
        router.addLP(liquidity);
    }

    // ── beat 1: a guarded-but-allowed withdrawal ──────────────────────
    function test_PartialWithdrawalPasses() public {
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(router));
        // netIM along the remaining-LP curve dips to $7.5k near 92k and rises
        // through $12k (the posted level) at ~$64k removed; 20% removed ≈
        // $24k → remaining ≈ $76k → required ≈ $9.5k < $12k posted → passes
        router.removeLP(liquidity / 5, 0);
        assertGt(IERC20(usdc).balanceOf(address(router)), usdcBefore, "partial removal did not release USDC");
    }

    // ── beat 2: the on-camera guard, the whole point of the demo ─────
    /// The LP-like PoolManager wraps the callback's revert in ERC-7751
    /// WrappedError(target, calleeSelector, originalRevertData, details).
    /// Unwrap it and assert the guard's own data traveled intact.
    function test_HookRealPool_BlocksFullWithdrawal() public {
        // remaining LP 0 ⇒ the required margin is the isolated short's own IM
        uint256 requiredIM = SpanMathLib.evaluateSpan16(0, SHORT_N).netInitialMarginUsdc;
        try router.removeLP(liquidity, 0) {
            fail("full withdrawal passed; the guard never tripped");
        } catch (bytes memory err) {
            bytes memory wrapperTail = new bytes(err.length - 4);
            for (uint256 i = 0; i < wrapperTail.length; ++i) wrapperTail[i] = err[4 + i];
            (address revertedTarget, , bytes memory innerRevert, ) = abi.decode(wrapperTail, (address, bytes4, bytes, bytes));
            assertEq(revertedTarget, address(hook), "the revert must originate in the hook");
            assertEq(bytes4(innerRevert), PortfolioMarginHook.SpanMarginBreach.selector, "the guard's error must survive the bubble");
            bytes memory innerTail = new bytes(innerRevert.length - 4);
            for (uint256 i = 0; i < innerTail.length; ++i) innerTail[i] = innerRevert[4 + i];
            (address seenTrader, uint256 seenPostEquity, uint256 seenRequiredIM) =
                abi.decode(innerTail, (address, uint256, uint256));
            assertEq(seenTrader, address(router), "the trader is the router by design");
            assertEq(seenPostEquity, POSTED, "post-equity is the unmarked posted margin");
            assertEq(seenRequiredIM, requiredIM, "required-im is the engine's own figure");
        }
    }

    // ── mark price flows through the real afterSwap channel ─────────
    function test_AfterSwap_KeepsMarkFresh() public {
        uint64 beforeMark = app.markPriceUsdc();
        // swap 10k USDC → WETH (zeroForOne=false): WETH appreciates; the mark
        // should move ABOVE its entry price through the real afterSwap path
        router.swap(false, -int256(10_000e6), TickMath.MAX_SQRT_PRICE - 1);
        uint64 afterMark = app.markPriceUsdc();
        assertGt(afterMark, beforeMark, "afterSwap pushed no fresh mark");
    }

    function _mineUsdcAbove(address wethAddr) internal view returns (uint256 salt, address usdcAt) {        bytes32 codeHash = keccak256(abi.encodePacked(type(MockUSDC).creationCode, abi.encode(address(this))));
        for (uint256 s = 1; s < 3_000; ++s) {
            address at = vm.computeCreate2Address(bytes32(s), codeHash, CREATE2_FACTORY);
            if (uint160(at) > uint160(wethAddr)) return (s, at);
        }
        revert("no salt above WETH in 3k tries");
    }
}
