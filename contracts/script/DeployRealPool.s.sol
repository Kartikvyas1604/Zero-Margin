// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Math as OZMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ClearingAquaApp} from "../src/ClearingAquaApp.sol";
import {PortfolioMarginHook} from "../src/PortfolioMarginHook.sol";
import {ShortHedgeAdapter} from "../src/ShortHedgeAdapter.sol";
import {MockAqua} from "../src/MockAqua.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {DemoLPRouter, IClearingAquaApp} from "../src/DemoLPRouter.sol";
import {IAqua} from "../src/interfaces/IAqua.sol";
import {IClearingMarginEngine} from "../src/interfaces/IClearingMarginEngine.sol";
import {MockUSDC} from "../../test/mocks/MockAqua.sol";
import {IPoolManager, PoolKey} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

/// @dev Deploys the demo stack against a REAL Uniswap v4 pool:
/// the mined 0x240 hook, the app bound to the REAL derived pool id, a
/// DemoLPRouter as trader, then pool init at the $3,000 folded mark, LP
/// seed, and the open GV-01 book. After this script a live LP withdrawal
/// through the real PoolManager exercises the guard end-to-end.
///
/// Needs `DEMO_PRIVATE_KEY` funded with gas (--private-key) and
/// `POOL_MANAGER_ADDRESS` (sepolia canonical per Agent.md). Run via
/// `make deploy-testnet-pool`.
contract DeployRealPool is Script {
    uint160 internal constant REQUIRED_FLAGS = 0x240; // beforeRemoveLiquidity | afterSwap
    address internal CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant Q192 = 2 ** 192;
    bytes32 internal constant STRATEGY = keccak256("ZEROMARGIN-DEMO-STRATEGY");

    function run() external {
        address broadcaster = msg.sender;
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        uint256 startNonce = vm.getNonce(broadcaster);

        vm.startBroadcast();

        // plain `new` order (each creation bumps the nonce): 0 MockWETH,
        // 1 DemoLPRouter, 2 MockAqua, 3 adapter, 4 app — the app's address
        // is predictable now. The mined USDC and mined hook go through the
        // CREATE2 factory, which consumes no nonce, so the count holds.
        address appAddress = vm.computeCreateAddress(broadcaster, startNonce + 4);

        // 1. WETH first (currency0), then the router (token-free constructor)
        MockWETH weth = new MockWETH(broadcaster);
        DemoLPRouter router = new DemoLPRouter(manager, broadcaster);

        // 2. USDC CREATE2-mined ABOVE the WETH so the pair orders
        //    currency0 = volatile — what the hook's USD math assumes
        (uint256 salt, address usdcAddr) = _mineUsdcAbove(address(weth));
        bytes32 usdcNameHash = keccak256(abi.encodePacked(type(MockUSDC).creationCode, abi.encode(broadcaster)));
        (bool ok, ) = CREATE2_DEPLOYER.call(abi.encodePacked(bytes32(salt), type(MockUSDC).creationCode, abi.encode(broadcaster)));
        require(ok, "mined USDC create failed");
        require(usdcAddr == vm.computeCreate2Address(bytes32(salt), usdcNameHash, CREATE2_DEPLOYER), "USDC addr drift");
        MockUSDC usdc = MockUSDC(usdcAddr);

        // 3. local Aqua + adapter (constructor auto-binds the app by address)
        MockAqua aqua = new MockAqua(IERC20(usdcAddr));
        ShortHedgeAdapter adapter = new ShortHedgeAdapter(IAqua(address(aqua)), usdcAddr, appAddress, broadcaster);

        // 4. the mined hook — the placeholder id rides in the mined args;
        //    setPoolId binds the real one after init (the circle-breaker)
        bytes32 placeholderId = keccak256("zeromargin.real-pool-placeholder");
        bytes32 hookInitArgsHash =
            keccak256(abi.encodePacked(type(PortfolioMarginHook).creationCode, abi.encode(manager, placeholderId, address(weth), broadcaster)));
        (address hookAddress, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER, REQUIRED_FLAGS,
            type(PortfolioMarginHook).creationCode,
            abi.encode(manager, placeholderId, address(weth), broadcaster)
        );
        (ok, ) = CREATE2_DEPLOYER.call(abi.encodePacked(hookSalt, type(PortfolioMarginHook).creationCode, abi.encode(manager, placeholderId, address(weth), broadcaster)));
        require(ok, "mined hook create failed");
        require(hookAddress == vm.computeCreate2Address(hookSalt, hookInitArgsHash, CREATE2_DEPLOYER), "hook addr drift");
        PortfolioMarginHook hook = PortfolioMarginHook(hookAddress);

        // 5. real pool id from the key that includes the mined hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(usdcAddr),
            fee: uint24(500),
            tickSpacing: int24(10),
            hooks: IHooks(hookAddress)
        });
        bytes32 realPoolId = keccak256(abi.encode(key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks));

        // the app lands on the predicted nonce
        require(appAddress == vm.computeCreateAddress(broadcaster, vm.getNonce(broadcaster)), "app prediction drifted");
        ClearingAquaApp app = new ClearingAquaApp(IAqua(address(aqua)), usdcAddr, address(adapter), broadcaster, realPoolId, 3_000e6);

        // 6. wire-up, then renounce both owners
        app.setHook(hookAddress);
        hook.setEngine(IClearingMarginEngine(address(app)));
        hook.setPoolId(realPoolId);
        router.setAqua(IAqua(address(aqua)));
        router.setUsdc(IERC20(usdcAddr));
        router.setApp(IClearingAquaApp(address(app)));
        router.setPool(key);
        router.approveAll();
        app.renounceOwnership();
        hook.renounceOwnership();

        // 7. fund: LP seed to the router, hedge reserve to the adapter.
        // addLP needs ~20 WETH + the full 60k USDC, on top of the 25k ship
        usdc.transfer(address(router), 100_000e6);
        weth.transfer(address(router), 30e18);
        usdc.approve(address(adapter), 100_000e6);
        adapter.fundReserve(100_000e6);

        // 8. pool init at the $3,000 folded mark (18-dec WETH / 6-dec USDC:
        //    rawPrice = 3000e6/1e18 — the exact fold the guard's USD math assumes)
        uint160 sqrtP3000 = uint160(OZMath.sqrt((uint256(3_000e6) * Q192) / 1e18));
        manager.initialize(key, sqrtP3000);

        // 9. the GV-04 golden open, FROM the router (the engine's trader
        //    address): posted 12_000e6 — lean enough that the full-LP
        //    withdrawal trip happens with the exact golden revert data
        router.openBook(uint128(100_000e6), uint128(95_000e6), uint128(12_000e6), STRATEGY);

        // 10. LP seed: ~$60k on each side, full range for the spacing-10 pool
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP3000,
            TickMath.MIN_SQRT_PRICE + 1,
            TickMath.MAX_SQRT_PRICE - 1,
            uint256(20e18),      // WETH side wish: $60k at $3,000
            uint256(60_000e6)    // USDC side wish: $60k
        );
        require(liquidity > 0, "liquidity solved to zero");
        router.addLP(liquidity);

        vm.stopBroadcast();

        console.log("MockWETH(demo)         ", address(weth));
        console.log("MockUSDC(demo)         ", usdcAddr);
        console.log("MockAqua               ", address(aqua));
        console.log("ShortHedgeAdapter      ", address(adapter));
        console.log("ClearingAquaApp        ", address(app));
        console.log("PortfolioMarginHook    ", hookAddress);
        console.log("DemoLPRouter           ", address(router));
        console.logBytes32(realPoolId);
        console.log("LP liquidity seeded    ", liquidity);
        console.log("demo trader (router)   ", address(router));
    }

    /// smallest salt whose CREATE2 USDC lands ABOVE the WETH, so
    /// currency0 < currency1 in the pool key, per v4's address ordering
    function _mineUsdcAbove(address wethAddr) internal view returns (uint256 salt, address usdcAt) {
        bytes32 codeHash = usdcNameHash();
        for (uint256 s = 1; s < 300_000; ++s) {
            address at = vm.computeCreate2Address(bytes32(s), codeHash, CREATE2_DEPLOYER);
            if (uint160(at) > uint160(wethAddr)) return (s, at);
        }
        revert("no salt above the WETH in 300k tries");
    }

    function usdcNameHash() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(type(MockUSDC).creationCode, abi.encode(msg.sender)));
    }
}
