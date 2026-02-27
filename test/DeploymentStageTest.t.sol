// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {LPSplitHookTestBase} from "./TestBase.sol";
import {UniV3DeploymentSplitHook} from "../src/UniV3DeploymentSplitHook.sol";
import {IUniV3DeploymentSplitHook} from "../src/interfaces/IUniV3DeploymentSplitHook.sol";
import {JBSplitHookContext} from "@bananapus/core/structs/JBSplitHookContext.sol";

/// @notice Tests for UniV3DeploymentSplitHook deployment stage behavior.
/// @dev Covers deployPool, processSplitWith auto-deploy, token burning, leftovers, and revert conditions.
contract DeploymentStageTest is LPSplitHookTestBase {

    function setUp() public override {
        super.setUp();
    }

    // ─────────────────────────────────────────────────────────────────────
    // 1. deployPool — creates pool and sets poolOf
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After accumulating tokens in accumulation stage, deployPool should create the pool
    ///         and set poolOf to a nonzero address.
    function test_DeployPool_CreatesPool() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2. deployPool — cashes out half of accumulated tokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should cash out half of accumulated project tokens to get terminal tokens.
    ///         After accumulating 100e18, it should cash out 50e18.
    function test_DeployPool_CashesOutHalf() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(terminal.cashOutCallCount(), 1, "cashOutTokensOf should be called once");
        assertEq(terminal.lastCashOutAmount(), 50e18, "cashOut amount should be half of accumulated (50e18)");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 3. deployPool — mints LP position via NFPM
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should call NFPM.mint exactly once to create the LP position.
    function test_DeployPool_MintsLPPosition() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(nfpm.mintCallCount(), 1, "NFPM mint should be called once");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 4. deployPool — sets tokenIdForPool
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, tokenIdForPool for the created pool should be nonzero.
    function test_DeployPool_SetsTokenId() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 tokenId = hook.tokenIdForPool(pool);
        assertTrue(tokenId != 0, "tokenIdForPool should be nonzero after deployPool");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 5. deployPool — clears accumulatedProjectTokens
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After deployment, accumulatedProjectTokens should be reset to 0.
    function test_DeployPool_ClearsAccumulated() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        assertEq(
            hook.accumulatedProjectTokens(PROJECT_ID),
            0,
            "accumulatedProjectTokens should be 0 after deployment"
        );
    }

    // ─────────────────────────────────────────────────────────────────────
    // 6. deployPool — emits ProjectDeployed event
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool should emit ProjectDeployed with the correct projectId and terminalToken.
    function test_DeployPool_EmitsEvent() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Check indexed params: projectId (topic1) and terminalToken (topic2)
        // The pool address (topic3) is unknown ahead of time, so we only check the first two indexed params.
        vm.expectEmit(true, true, false, false);
        emit IUniV3DeploymentSplitHook.ProjectDeployed(PROJECT_ID, address(terminalToken), address(0));

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 7. deployPool — reverts if no tokens accumulated
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with NoTokensAccumulated when no tokens have been accumulated.
    function test_DeployPool_RevertsIf_NoTokens() public {
        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_NoTokensAccumulated.selector);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 8. deployPool — reverts if not in accumulation stage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with InvalidStageForAction when called in deployment stage
    ///         (i.e., when weight has dropped below 10% threshold).
    function test_DeployPool_RevertsIf_NotAccumulationStage() public {
        // Accumulate first so the NoTokensAccumulated check would pass
        _accumulateTokens(PROJECT_ID, 100e18);

        // Drop weight below threshold to enter deployment stage
        _enterDeploymentStage(PROJECT_ID);

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidStageForAction.selector);
        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 9. deployPool — reverts if terminal token is invalid
    // ─────────────────────────────────────────────────────────────────────

    /// @notice deployPool reverts with InvalidTerminalToken when using a token that has
    ///         no primary terminal configured in the directory.
    function test_DeployPool_RevertsIf_InvalidTerminal() public {
        _accumulateTokens(PROJECT_ID, 100e18);

        // Use an address with no terminal configured
        address invalidToken = makeAddr("invalidToken");

        vm.expectRevert(UniV3DeploymentSplitHook.UniV3DeploymentSplitHook_InvalidTerminalToken.selector);
        hook.deployPool(PROJECT_ID, invalidToken, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // 10. processSplitWith — auto-deploys pool on first call in deployment stage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When processSplitWith is called in deployment stage with accumulated tokens
    ///         and no pool exists yet, it should auto-deploy the pool.
    function test_ProcessSplit_DeploysPoolFirstTime() public {
        // Accumulate tokens while still in accumulation stage
        _accumulateTokens(PROJECT_ID, 100e18);

        // Transition to deployment stage by dropping weight below threshold
        _enterDeploymentStage(PROJECT_ID);

        // Send new tokens to hook and call processSplitWith as the controller
        uint256 newAmount = 10e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Pool should have been auto-deployed
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertTrue(pool != address(0), "poolOf should be nonzero after auto-deploy via processSplitWith");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 11. processSplitWith — burns new tokens after pool exists
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool already exists, processSplitWith in deployment stage should
    ///         burn the newly received project tokens via the controller.
    function test_ProcessSplit_BurnsNewTokens() public {
        // Deploy pool first
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Reset burn tracking after deploy (deploy may have burned leftovers)
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Transition to deployment stage
        _enterDeploymentStage(PROJECT_ID);

        // Send new tokens to hook
        uint256 newAmount = 50e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Verify burn was called for the newly received tokens
        assertTrue(
            controller.burnCallCount() > burnCountAfterDeploy,
            "controller.burnTokensOf should be called after receiving tokens in deployment stage"
        );
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "burn should be for the correct project");
        assertEq(controller.lastBurnHolder(), address(hook), "burn should be from the hook address");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 12. processSplitWith — no accumulated tokens, skips deploy, still burns
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When entering deployment stage with 0 accumulated tokens, processSplitWith
    ///         should NOT deploy a pool (poolOf stays address(0)) but should still burn
    ///         the newly received tokens.
    function test_ProcessSplit_NoAccumulation_SkipsDeploy() public {
        // Enter deployment stage without accumulating anything
        _enterDeploymentStage(PROJECT_ID);

        // Send some tokens to hook
        uint256 newAmount = 10e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Pool should NOT have been deployed
        address pool = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertEq(pool, address(0), "poolOf should remain address(0) when no tokens were accumulated");

        // But the newly received tokens should still be burned
        assertTrue(controller.burnCallCount() > 0, "burn should still be called for newly received tokens");
        assertEq(controller.lastBurnHolder(), address(hook), "burn should be from the hook");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 13. deployPool — handles leftover tokens when NFPM uses less than 100%
    // ─────────────────────────────────────────────────────────────────────

    /// @notice When NFPM uses less than 100% of desired amounts (e.g., 80%), leftover project
    ///         tokens should be burned via the controller.
    function test_DeployPool_HandlesBurnOfLeftovers() public {
        // Set NFPM to only use 80% of desired amounts
        nfpm.setUsagePercent(8000);

        _accumulateTokens(PROJECT_ID, 100e18);

        hook.deployPool(PROJECT_ID, address(terminalToken), 0, 0);

        // The hook should have called burnTokensOf for leftover project tokens
        assertTrue(controller.burnCallCount() > 0, "controller.burnTokensOf should be called for leftover tokens");
        assertEq(controller.lastBurnProjectId(), PROJECT_ID, "leftover burn should target the correct project");
        assertEq(controller.lastBurnHolder(), address(hook), "leftover burn should be from the hook");
    }

    // ─────────────────────────────────────────────────────────────────────
    // 14. deployPool once, then processSplitWith — only burns, no second pool
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After the pool has been deployed, calling processSplitWith again should NOT
    ///         create a second pool. It should only burn the newly received tokens.
    function test_DeployPool_PoolAlreadyExists_OnlyBurns() public {
        // Deploy pool in accumulation stage
        _accumulateAndDeploy(PROJECT_ID, 100e18);

        // Record pool address and NFPM mint count after first deploy
        address firstPool = hook.poolOf(PROJECT_ID, address(terminalToken));
        uint256 mintCountAfterDeploy = nfpm.mintCallCount();
        uint256 burnCountAfterDeploy = controller.burnCallCount();

        // Transition to deployment stage
        _enterDeploymentStage(PROJECT_ID);

        // Send new tokens and call processSplitWith
        uint256 newAmount = 25e18;
        projectToken.mint(address(hook), newAmount);

        JBSplitHookContext memory context = _buildReservedContext(PROJECT_ID, newAmount);

        vm.prank(address(controller));
        hook.processSplitWith(context);

        // Pool address should remain the same (no second pool created)
        address poolAfter = hook.poolOf(PROJECT_ID, address(terminalToken));
        assertEq(poolAfter, firstPool, "pool address should not change after second processSplitWith");

        // NFPM.mint should NOT have been called again
        assertEq(nfpm.mintCallCount(), mintCountAfterDeploy, "NFPM mint should not be called again");

        // But burn should have been called for the new tokens
        assertTrue(
            controller.burnCallCount() > burnCountAfterDeploy,
            "burn should be called for newly received tokens when pool already exists"
        );
    }
}
