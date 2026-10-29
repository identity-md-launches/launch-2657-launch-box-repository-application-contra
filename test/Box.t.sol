// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Box} from "../src/Box.sol";
import {BoxSigning} from "./helpers/BoxSigning.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUsd is ERC20("imdUSD", "imdUSD") {
    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract BoxTest is Test {
    Box box;
    IERC20 usd;
    address treasury = makeAddr("treasury");
    address float_ = makeAddr("float");
    uint256 signerKey = 0xB0B;
    address signer;
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");
    bytes32 constant ORDER = keccak256("order-1");
    bytes32 constant BODY = keccak256("body");

    function _token() internal virtual returns (IERC20) {
        MockUsd t = new MockUsd();
        t.mint(alice, 1_000e18);
        t.mint(mallory, 1_000e18);
        return IERC20(address(t));
    }

    function setUp() public virtual {
        signer = vm.addr(signerKey);
        usd = _token();
        box = new Box(usd, treasury, float_, signer);
        vm.prank(alice);
        usd.approve(address(box), type(uint256).max);
        vm.prank(mallory);
        usd.approve(address(box), type(uint256).max);
    }

    function _sign(Box.Settlement memory s, uint256 key) internal view returns (bytes memory) {
        bytes32 digest = BoxSigning.digest(address(box), block.chainid, s);
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(key, digest);
        return abi.encodePacked(r, ss, v);
    }

    function _pay(address who, uint256 f, uint256 t, uint256 e) internal returns (bytes32) {
        vm.prank(who);
        return box.pay(ORDER, BODY, f, t, e, bytes32("ref"));
    }

    function test_payRoutesFunds() public {
        uint256 fb = usd.balanceOf(float_);
        uint256 tb = usd.balanceOf(treasury);
        uint256 ab = usd.balanceOf(alice);
        bytes32 key = _pay(alice, 2.28e18, 0.114e18, 4.56e18);
        assertEq(usd.balanceOf(float_) - fb, 2.28e18);
        assertEq(usd.balanceOf(treasury) - tb, 0.114e18);
        assertEq(usd.balanceOf(address(box)), 4.56e18);
        assertEq(ab - usd.balanceOf(alice), 2.28e18 + 0.114e18 + 4.56e18);
        (address payer,, bool closed, uint128 escrow) = box.orders(key);
        assertEq(payer, alice);
        assertFalse(closed);
        assertEq(escrow, 4.56e18);
        assertEq(key, box.keyOf(alice, ORDER));
    }

    function test_payEmitsCommitment() public {
        vm.expectEmit(true, true, true, true, address(box));
        emit Box.Paid(box.keyOf(alice, ORDER), alice, ORDER, BODY, 1e18, 0.05e18, 0, bytes32("ref"));
        _pay(alice, 1e18, 0.05e18, 0);
    }

    function test_noEscrowOrderIsClosedAtOnce() public {
        bytes32 key = _pay(alice, 1e18, 0.05e18, 0);
        (,, bool closed,) = box.orders(key);
        assertTrue(closed);
        vm.warp(block.timestamp + 61 days);
        vm.prank(alice);
        vm.expectRevert(Box.OrderClosed.selector);
        box.reclaim(ORDER);
    }

    function test_sameOrderIdTwiceReverts() public {
        _pay(alice, 1e18, 0, 0);
        vm.prank(alice);
        vm.expectRevert(Box.OrderExists.selector);
        box.pay(ORDER, BODY, 1e18, 0, 0, 0);
    }

    function test_frontRunCannotSquatOrderId() public {
        // mallory sees alice's pending pay and uses the same orderId first: it lands under mallory's key, not alice's
        bytes32 mk = _pay(mallory, 1, 0, 0);
        bytes32 ak = _pay(alice, 1e18, 0, 0);
        assertTrue(mk != ak);
        (address p,,,) = box.orders(ak);
        assertEq(p, alice);
    }

    function test_nothingPaidReverts() public {
        vm.prank(alice);
        vm.expectRevert(Box.NothingPaid.selector);
        box.pay(ORDER, BODY, 0, 0, 0, 0);
    }

    function test_escrowTooLargeReverts() public {
        vm.prank(alice);
        vm.expectRevert(Box.EscrowTooLarge.selector);
        box.pay(ORDER, BODY, 0, 0, uint256(type(uint128).max) + 1, 0);
    }

    function test_settleSplitsEscrow() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        Box.Settlement memory s = Box.Settlement(key, 0.5e18, 1.5e18, 1e18);
        uint256 ab = usd.balanceOf(alice);
        uint256 fb = usd.balanceOf(float_);
        uint256 tb = usd.balanceOf(treasury);
        bytes memory sig = _sign(s, signerKey);
        vm.prank(mallory); // anyone may execute
        box.settle(s, sig);
        assertEq(usd.balanceOf(alice) - ab, 1e18);
        assertEq(usd.balanceOf(float_) - fb, 1.5e18);
        assertEq(usd.balanceOf(treasury) - tb, 0.5e18);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_settleWrongTotalReverts() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 3e18 + 1);
        bytes memory sig = _sign(s, signerKey);
        vm.expectRevert(Box.WrongTotal.selector);
        box.settle(s, sig);
    }

    function test_settleBadSignerReverts() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        Box.Settlement memory s = Box.Settlement(key, 0, 3e18, 0);
        bytes memory sig = _sign(s, 0xBAD);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, sig);
    }

    function test_settleSignatureBoundToKeyAndAmounts() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        bytes memory sig = _sign(Box.Settlement(key, 0, 0, 3e18), signerKey);
        // same signature, amounts redirected to the float
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(Box.Settlement(key, 0, 3e18, 0), sig);
        // same signature, another order with the same escrow
        bytes32 key2 = keccak256("x");
        key2 = _payOther(3e18);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(Box.Settlement(key2, 0, 0, 3e18), sig);
    }

    function _payOther(uint256 e) internal returns (bytes32) {
        vm.prank(mallory);
        return box.pay(keccak256("order-2"), BODY, 0, 0, e, 0);
    }

    function test_settleTwiceReverts() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 3e18);
        bytes memory sig = _sign(s, signerKey);
        box.settle(s, sig);
        vm.expectRevert(Box.OrderClosed.selector);
        box.settle(s, sig);
    }

    function test_settleUnknownReverts() public {
        Box.Settlement memory s = Box.Settlement(keccak256("nope"), 0, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.expectRevert(Box.UnknownOrder.selector);
        box.settle(s, sig);
    }

    function test_settleManyAllOrNothing() public {
        bytes32 k1 = _pay(alice, 0, 0, 1e18);
        bytes32 k2 = _payOther(2e18);
        Box.Settlement[] memory s = new Box.Settlement[](2);
        bytes[] memory sigs = new bytes[](2);
        s[0] = Box.Settlement(k1, 1e18, 0, 0);
        sigs[0] = _sign(s[0], signerKey);
        s[1] = Box.Settlement(k2, 0, 2e18, 0);
        sigs[1] = _sign(s[1], 0xBAD);
        vm.expectRevert(Box.BadSignature.selector);
        box.settleMany(s, sigs);
        sigs[1] = _sign(s[1], signerKey);
        box.settleMany(s, sigs);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_settleManyLengthMismatch() public {
        vm.expectRevert(Box.WrongTotal.selector);
        box.settleMany(new Box.Settlement[](1), new bytes[](0));
    }

    function test_reclaimAfter60Days() public {
        _pay(alice, 1e18, 0, 3e18);
        uint256 paidAt = vm.getBlockTimestamp();
        vm.warp(paidAt + 60 days - 1);
        vm.prank(alice);
        vm.expectRevert(Box.TooEarly.selector);
        box.reclaim(ORDER);
        vm.warp(paidAt + 60 days);
        uint256 ab = usd.balanceOf(alice);
        vm.prank(alice);
        box.reclaim(ORDER);
        assertEq(usd.balanceOf(alice) - ab, 3e18);
        vm.prank(alice);
        vm.expectRevert(Box.OrderClosed.selector);
        box.reclaim(ORDER);
    }

    function test_reclaimOnlyByPayer() public {
        _pay(alice, 1e18, 0, 3e18);
        vm.warp(block.timestamp + 61 days);
        vm.prank(mallory);
        vm.expectRevert(Box.UnknownOrder.selector);
        box.reclaim(ORDER);
    }

    function test_settledOrderCannotBeReclaimed() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        Box.Settlement memory s = Box.Settlement(key, 3e18, 0, 0);
        box.settle(s, _sign(s, signerKey));
        vm.warp(block.timestamp + 61 days);
        vm.prank(alice);
        vm.expectRevert(Box.OrderClosed.selector);
        box.reclaim(ORDER);
    }

    function test_reclaimedOrderCannotBeSettled() public {
        bytes32 key = _pay(alice, 1e18, 0, 3e18);
        vm.warp(block.timestamp + 61 days);
        vm.prank(alice);
        box.reclaim(ORDER);
        Box.Settlement memory s = Box.Settlement(key, 3e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.expectRevert(Box.OrderClosed.selector);
        box.settle(s, sig);
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(Box.ZeroAddress.selector);
        new Box(usd, address(0), float_, signer);
        vm.expectRevert(Box.ZeroAddress.selector);
        new Box(usd, treasury, float_, address(0));
    }

    /// The box never holds more than the open escrow, whatever sequence of pays and settles runs.
    function testFuzz_balanceEqualsOpenEscrow(uint96 e1, uint96 e2, uint96 split) public {
        e1 = uint96(bound(e1, 1, 400e18));
        e2 = uint96(bound(e2, 1, 400e18));
        bytes32 k1 = _pay(alice, 0, 0, e1);
        bytes32 k2 = _payOther(e2);
        assertEq(usd.balanceOf(address(box)), uint256(e1) + e2);
        uint256 toP = bound(split, 0, e1);
        Box.Settlement memory s = Box.Settlement(k1, 0, e1 - toP, toP);
        box.settle(s, _sign(s, signerKey));
        assertEq(usd.balanceOf(address(box)), e2);
        k2; // e2 stays open
    }

    // ---- settleMany skips closed orders (audit finding ca391bf9: a third party could revert the whole batch) ----

    function _batch(bytes32 k1, bytes32 k2) internal view returns (Box.Settlement[] memory s, bytes[] memory sigs) {
        s = new Box.Settlement[](2);
        sigs = new bytes[](2);
        s[0] = Box.Settlement(k1, 1e18, 0, 0);
        sigs[0] = _sign(s[0], signerKey);
        s[1] = Box.Settlement(k2, 0, 2e18, 0);
        sigs[1] = _sign(s[1], signerKey);
    }

    function test_settleManySkipsOrderReclaimedAhead() public {
        bytes32 k1 = _pay(alice, 0, 0, 1e18);
        bytes32 k2 = _payOther(2e18);
        (Box.Settlement[] memory s, bytes[] memory sigs) = _batch(k1, k2);
        vm.warp(block.timestamp + 61 days);
        uint256 ab = usd.balanceOf(alice);
        uint256 fb = usd.balanceOf(float_);
        uint256 tb = usd.balanceOf(treasury);
        vm.prank(alice); // lands before the keeper's batch
        box.reclaim(ORDER);
        box.settleMany(s, sigs);
        assertEq(usd.balanceOf(alice) - ab, 1e18); // alice got her escrow back once, the treasury nothing
        assertEq(usd.balanceOf(treasury), tb);
        assertEq(usd.balanceOf(float_) - fb, 2e18); // the other entry settled
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_settleManySkipsOrderSettledAhead() public {
        bytes32 k1 = _pay(alice, 0, 0, 1e18);
        bytes32 k2 = _payOther(2e18);
        (Box.Settlement[] memory s, bytes[] memory sigs) = _batch(k1, k2);
        uint256 fb = usd.balanceOf(float_);
        uint256 tb = usd.balanceOf(treasury);
        vm.prank(mallory); // copied from the pending batch
        box.settle(s[0], sigs[0]);
        box.settleMany(s, sigs);
        assertEq(usd.balanceOf(treasury) - tb, 1e18); // paid once, not twice
        assertEq(usd.balanceOf(float_) - fb, 2e18);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_settleManyDuplicateKeySettlesOnce() public {
        bytes32 k1 = _pay(alice, 0, 0, 1e18);
        _payOther(2e18); // stays open: the duplicate must not draw on it
        Box.Settlement[] memory s = new Box.Settlement[](2);
        bytes[] memory sigs = new bytes[](2);
        s[0] = Box.Settlement(k1, 1e18, 0, 0);
        sigs[0] = _sign(s[0], signerKey);
        s[1] = Box.Settlement(k1, 0, 0, 1e18);
        sigs[1] = _sign(s[1], signerKey);
        uint256 ab = usd.balanceOf(alice);
        uint256 tb = usd.balanceOf(treasury);
        box.settleMany(s, sigs);
        assertEq(usd.balanceOf(treasury) - tb, 1e18);
        assertEq(usd.balanceOf(alice), ab);
        assertEq(usd.balanceOf(address(box)), 2e18);
    }

    function test_settleManyStillRevertsOnUnknownOrWrongTotal() public {
        bytes32 k1 = _pay(alice, 0, 0, 1e18);
        Box.Settlement[] memory s = new Box.Settlement[](1);
        bytes[] memory sigs = new bytes[](1);
        s[0] = Box.Settlement(keccak256("nope"), 0, 0, 0);
        sigs[0] = _sign(s[0], signerKey);
        vm.expectRevert(Box.UnknownOrder.selector);
        box.settleMany(s, sigs);
        s[0] = Box.Settlement(k1, 2e18, 0, 0);
        sigs[0] = _sign(s[0], signerKey);
        vm.expectRevert(Box.WrongTotal.selector);
        box.settleMany(s, sigs);
    }

    // ---- signature replay and malleability ----

    function test_replayOnOtherChainIdRejected() public {
        bytes32 key = _pay(alice, 0, 0, 1e18);
        Box.Settlement memory s = Box.Settlement(key, 1e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, sig);
    }

    function test_replayOnOtherBoxRejected() public {
        bytes32 key = _pay(alice, 0, 0, 1e18);
        Box.Settlement memory s = Box.Settlement(key, 1e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        Box box2 = new Box(usd, treasury, float_, signer);
        vm.startPrank(alice);
        usd.approve(address(box2), type(uint256).max);
        box2.pay(ORDER, BODY, 0, 0, 1e18, 0); // same (payer, orderId) key on another box
        vm.stopPrank();
        vm.expectRevert(Box.BadSignature.selector);
        box2.settle(s, sig);
    }

    function test_settlementSignedBeforePayStillBoundToEscrow() public {
        bytes32 key = box.keyOf(alice, ORDER);
        Box.Settlement memory s = Box.Settlement(key, 1e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.expectRevert(Box.UnknownOrder.selector);
        box.settle(s, sig);
        _pay(alice, 0, 0, 2e18); // escrow differs from the pre-signed split
        vm.expectRevert(Box.WrongTotal.selector);
        box.settle(s, sig);
    }

    function test_highSMalleatedSignatureRejected() public {
        bytes32 key = _pay(alice, 0, 0, 1e18);
        Box.Settlement memory s = Box.Settlement(key, 1e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        bytes32 r;
        bytes32 ss;
        assembly {
            r := mload(add(sig, 32))
            ss := mload(add(sig, 64))
        }
        uint8 v = uint8(sig[64]);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory mal = abi.encodePacked(r, bytes32(n - uint256(ss)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, mal);
        box.settle(s, sig);
    }

    function test_compactAndBadVSignaturesRejected() public {
        bytes32 key = _pay(alice, 0, 0, 1e18);
        Box.Settlement memory s = Box.Settlement(key, 1e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        bytes32 r;
        bytes32 ss;
        assembly {
            r := mload(add(sig, 32))
            ss := mload(add(sig, 64))
        }
        uint8 v = uint8(sig[64]);
        bytes32 vs = bytes32(uint256(ss) | (v == 28 ? uint256(1) << 255 : 0));
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, abi.encodePacked(r, vs));
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, abi.encodePacked(r, ss, uint8(v - 27)));
    }

    // ---- the 60-day boundary ----

    function test_settleAndReclaimBothOpenAtBoundary() public {
        bytes32 key = _pay(alice, 0, 0, 2e18);
        Box.Settlement memory s = Box.Settlement(key, 2e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.warp(block.timestamp + 60 days);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        box.reclaim(ORDER);
        vm.expectRevert(Box.OrderClosed.selector);
        box.settle(s, sig);
        vm.revertToState(snap);
        box.settle(s, sig);
        vm.prank(alice);
        vm.expectRevert(Box.OrderClosed.selector);
        box.reclaim(ORDER);
    }

    function test_settleLongAfterBoundary() public {
        bytes32 key = _pay(alice, 0, 0, 2e18);
        Box.Settlement memory s = Box.Settlement(key, 2e18, 0, 0);
        bytes memory sig = _sign(s, signerKey);
        vm.warp(block.timestamp + 400 days);
        uint256 tb = usd.balanceOf(treasury);
        box.settle(s, sig);
        assertEq(usd.balanceOf(treasury) - tb, 2e18);
    }

    // ---- packing ----

    function test_maxUint128EscrowAndLateTimestamp() public {
        uint256 max = type(uint128).max;
        deal(address(usd), alice, max);
        vm.warp(uint256(type(uint64).max) - 61 days);
        bytes32 key = _pay(alice, 0, 0, max);
        (address payer, uint64 paidAt, bool closed, uint128 escrow) = box.orders(key);
        assertEq(payer, alice);
        assertEq(paidAt, uint64(block.timestamp));
        assertFalse(closed);
        assertEq(escrow, max);
        vm.warp(block.timestamp + 60 days);
        vm.prank(alice);
        box.reclaim(ORDER);
        assertEq(usd.balanceOf(alice), max);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    // ---- documented consequences (no code change) ----

    function test_twoWalletsPayingSameOrderIdAreSeparateOrders() public {
        bytes32 ka = _pay(alice, 1e18, 0.05e18, 2e18);
        bytes32 km = _pay(mallory, 1e18, 0.05e18, 2e18);
        assertTrue(ka != km);
        (address pa,,,) = box.orders(ka);
        (address pm,,,) = box.orders(km);
        assertEq(pa, alice); // Paid.payer tells the two apart
        assertEq(pm, mallory);
        assertEq(usd.balanceOf(address(box)), 4e18);
    }

    function test_directTransferIsNotEscrowAndCannotLeave() public {
        vm.prank(mallory);
        usd.transfer(address(box), 5e18);
        bytes32 key = _pay(alice, 0, 0, 1e18);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 6e18);
        bytes memory sig = _sign(s, signerKey);
        vm.expectRevert(Box.WrongTotal.selector);
        box.settle(s, sig);
        s = Box.Settlement(key, 0, 0, 1e18);
        box.settle(s, _sign(s, signerKey));
        assertEq(usd.balanceOf(address(box)), 5e18);
    }

    // Independent audit checks below also run unchanged in BoxForkTest.

    struct PaidData {
        bytes32 commitment;
        uint256 toFloat;
        uint256 toTreasury;
        uint256 escrow;
        bytes32 ref;
    }

    /// Snapshot all accounts affected by these tests, including spent allowances and order metadata.
    function _auditState(bytes32[] memory keys) internal view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                usd.balanceOf(alice),
                usd.balanceOf(mallory),
                usd.balanceOf(treasury),
                usd.balanceOf(float_),
                usd.balanceOf(address(box)),
                usd.allowance(alice, address(box)),
                usd.allowance(mallory, address(box))
            )
        );
        for (uint256 i; i < keys.length; ++i) {
            (address p, uint64 at, bool closed, uint128 escrow) = box.orders(keys[i]);
            state = keccak256(abi.encode(state, keys[i], p, at, closed, escrow));
        }
    }

    function _oneKey(bytes32 key) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = key;
    }

    function _assertOrder(bytes32 key, address payer, uint64 paidAt, bool closed, uint128 escrow) internal view {
        (address actualPayer, uint64 actualAt, bool actualClosed, uint128 actualEscrow) = box.orders(key);
        assertEq(actualPayer, payer, "payer changed");
        assertEq(actualAt, paidAt, "paidAt changed");
        assertEq(actualClosed, closed, "incorrect order lifecycle");
        assertEq(actualEscrow, escrow, "escrow truncated or changed");
    }

    function test_domainMatchesOperatorEncodingAndRefreshesOnChainChange() public {
        assertEq(
            box.SETTLEMENT_TYPEHASH(),
            keccak256("Settlement(bytes32 key,uint256 toTreasury,uint256 toFloat,uint256 toPayer)")
        );
        uint256 oldChain = block.chainid; // Intentionally retain the original chain id across the mutations below.
        bytes32 oldDomain = BoxSigning.domain(address(box), oldChain);
        assertEq(box.domainSeparator(), oldDomain);
        vm.chainId(oldChain + 1);
        assertEq(box.domainSeparator(), BoxSigning.domain(address(box), oldChain + 1));
        assertNotEq(box.domainSeparator(), oldDomain);
        vm.chainId(oldChain);
        assertEq(box.domainSeparator(), oldDomain);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PaidCanBeMatchedAgainstEveryQuoteField(
        bytes32 orderId,
        bytes32 commitment,
        bytes32 ref,
        uint96 f,
        uint96 t,
        uint96 e
    ) public {
        f = uint96(bound(f, 0, 100e18));
        t = uint96(bound(t, 0, 100e18));
        e = uint96(bound(e, 1, 100e18));
        bytes32 expectedKey = keccak256(abi.encode(alice, orderId));
        vm.recordLogs();
        vm.prank(alice);
        assertEq(box.pay(orderId, commitment, f, t, e, ref), expectedKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paidCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(box)) continue;
            ++paidCount;
            assertEq(logs[i].topics.length, 4);
            assertEq(
                logs[i].topics[0], keccak256("Paid(bytes32,address,bytes32,bytes32,uint256,uint256,uint256,bytes32)")
            );
            assertEq(logs[i].topics[1], expectedKey);
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))));
            assertEq(logs[i].topics[3], orderId);
            PaidData memory data = abi.decode(logs[i].data, (PaidData));
            assertEq(data.commitment, commitment);
            assertEq(data.toFloat, f);
            assertEq(data.toTreasury, t);
            assertEq(data.escrow, e);
            assertEq(data.ref, ref);
        }
        assertEq(paidCount, 1, "operator must see exactly one complete Paid");
        _assertOrder(expectedKey, alice, uint64(block.timestamp), false, e);
    }

    function test_zeroOrderIdAndOneWeiEscrowRoundTrip() public {
        uint256 beforeBalance = usd.balanceOf(alice);
        vm.prank(alice);
        bytes32 key = box.pay(bytes32(0), bytes32(0), 0, 0, 1, bytes32(0));
        assertEq(key, keccak256(abi.encode(alice, bytes32(0))));
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 1);
        bytes memory sig = _sign(s, signerKey);
        vm.expectEmit(true, false, false, true, address(box));
        emit Box.Settled(key, 0, 0, 1);
        vm.prank(mallory);
        box.settle(s, sig);
        assertEq(usd.balanceOf(alice), beforeBalance);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_zeroPaymentLegsDoNotCallToken() public {
        vm.mockCallRevert(address(usd), abi.encodeCall(IERC20.transferFrom, (alice, float_, 0)), bytes("zero float"));
        vm.mockCallRevert(
            address(usd), abi.encodeCall(IERC20.transferFrom, (alice, treasury, 0)), bytes("zero treasury")
        );
        vm.mockCallRevert(
            address(usd), abi.encodeCall(IERC20.transferFrom, (alice, address(box), 0)), bytes("zero escrow")
        );
        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            bytes32 key = box.pay(bytes32(i), 0, i == 0 ? 1 : 0, i == 1 ? 1 : 0, i == 2 ? 1 : 0, 0);
            _assertOrder(key, alice, uint64(block.timestamp), i != 2, i == 2 ? 1 : 0);
        }
        vm.clearMockedCalls();
        assertEq(usd.balanceOf(address(box)), 1);
    }

    function test_payTotalOverflowCannotCreateAnOrder() public {
        bytes32[] memory keys = _oneKey(box.keyOf(alice, ORDER));
        bytes32 beforeState = _auditState(keys);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _pay(alice, type(uint256).max, 1, 0);
        assertEq(_auditState(keys), beforeState);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _pay(alice, type(uint256).max - 1, 1, 1);
        assertEq(_auditState(keys), beforeState);
        vm.expectRevert(Box.EscrowTooLarge.selector);
        _pay(alice, 0, 0, type(uint256).max);
        assertEq(_auditState(keys), beforeState);
    }

    function test_paymentFailuresAtEachLegRollBackBalancesAllowanceAndOrder() public {
        // Fail at FLOAT, then TREASURY, then escrow, after earlier legs have actually transferred.
        uint256[3] memory limits = [uint256(0), 11, 24];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 leg; leg < 3; ++leg) {
                uint256 snapshot = vm.snapshotState();
                if (mode == 0) {
                    vm.prank(alice);
                    usd.approve(address(box), limits[leg]);
                } else {
                    deal(address(usd), alice, limits[leg]);
                }
                bytes32[] memory keys = _oneKey(box.keyOf(alice, ORDER));
                bytes32 beforeState = _auditState(keys);
                // The live token and the mock use different insufficient-balance/allowance errors.
                vm.expectRevert();
                _pay(alice, 11, 13, 17);
                assertEq(_auditState(keys), beforeState, "failed pay was not atomic");
                _assertOrder(keys[0], address(0), 0, false, 0);
                deal(address(usd), alice, 41);
                vm.prank(alice);
                usd.approve(address(box), 41);
                _pay(alice, 11, 13, 17); // the failed attempt did not consume the id
                assertEq(usd.allowance(alice, address(box)), 0);
                assertEq(usd.balanceOf(alice), 0);
                assertEq(usd.balanceOf(address(box)), 17);
                assertTrue(vm.revertToStateAndDelete(snapshot));
            }
        }
    }

    function test_falseReturnAtEachPaymentLegIsAtomicAndRetryable() public {
        address[3] memory recipients = [float_, treasury, address(box)];
        uint256[3] memory amounts = [uint256(11), 13, 17];
        for (uint256 leg; leg < 3; ++leg) {
            uint256 snapshot = vm.snapshotState();
            bytes32[] memory keys = _oneKey(box.keyOf(alice, ORDER));
            bytes32 beforeState = _auditState(keys);
            vm.mockCall(
                address(usd),
                abi.encodeCall(IERC20.transferFrom, (alice, recipients[leg], amounts[leg])),
                abi.encode(false)
            );
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usd)));
            _pay(alice, 11, 13, 17);
            assertEq(_auditState(keys), beforeState);
            vm.clearMockedCalls();
            _pay(alice, 11, 13, 17);
            assertEq(usd.balanceOf(address(box)), 17);
            assertTrue(vm.revertToStateAndDelete(snapshot));
        }
    }

    function test_settlementTransferFailuresAreAtomicAndRetryable() public {
        bytes32 key = _pay(alice, 0, 0, 41);
        bytes32 other = _payOther(53);
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = key;
        keys[1] = other;
        Box.Settlement memory s = Box.Settlement(key, 11, 13, 17);
        bytes memory sig = _sign(s, signerKey);
        address[3] memory recipients = [treasury, float_, alice];
        uint256[3] memory amounts = [uint256(11), 13, 17];
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 leg; leg < 3; ++leg) {
                bytes32 beforeState = _auditState(keys);
                bytes memory callData = abi.encodeCall(IERC20.transfer, (recipients[leg], amounts[leg]));
                bytes memory reason = abi.encodeWithSignature("TokenTransferRejected()");
                if (mode == 0) {
                    vm.mockCall(address(usd), callData, abi.encode(false));
                    reason = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usd));
                } else {
                    vm.mockCallRevert(address(usd), callData, reason);
                }
                vm.expectRevert(reason);
                box.settle(s, sig);
                assertEq(_auditState(keys), beforeState, "failed settlement consumed escrow or closed order");
                vm.clearMockedCalls();
            }
        }
        box.settle(s, sig);
        assertEq(usd.balanceOf(address(box)), 53, "another order's escrow was touched");
        (,, bool closed,) = box.orders(other);
        assertFalse(closed);
    }

    function test_reclaimTransferFailureDoesNotConsumeClaim() public {
        bytes32 key = _pay(alice, 0, 0, 17);
        vm.warp(block.timestamp + 60 days);
        bytes32[] memory keys = _oneKey(key);
        bytes32 beforeState = _auditState(keys);
        vm.mockCall(address(usd), abi.encodeCall(IERC20.transfer, (alice, 17)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usd)));
        vm.prank(alice);
        box.reclaim(ORDER);
        assertEq(_auditState(keys), beforeState);
        vm.clearMockedCalls();
        uint256 beforeBalance = usd.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(box));
        emit Box.Reclaimed(key, alice, 17);
        vm.prank(alice);
        box.reclaim(ORDER);
        assertEq(usd.balanceOf(alice), beforeBalance + 17);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_badBatchEntryRollsBackEveryEarlierEntry(uint8 position, uint8 failure) public {
        uint256 index = bound(position, 0, 3);
        uint256 kind = bound(failure, 0, 3);
        Box.Settlement[] memory batch = new Box.Settlement[](4);
        bytes[] memory sigs = new bytes[](4);
        bytes32[] memory keys = new bytes32[](4);
        for (uint256 i; i < 4; ++i) {
            vm.prank(i % 2 == 0 ? alice : mallory);
            keys[i] = box.pay(bytes32(i), BODY, 0, 0, 5e18, 0);
            batch[i] = Box.Settlement(keys[i], 1e18, 2e18, 2e18);
            sigs[i] = _sign(batch[i], signerKey);
        }
        bytes32 beforeState = _auditState(keys);
        bytes memory expected;
        if (kind == 0) {
            batch[index].key = keccak256("never paid");
            expected = abi.encodeWithSelector(Box.UnknownOrder.selector);
        } else if (kind == 1) {
            batch[index].toPayer += 1;
            expected = abi.encodeWithSelector(Box.WrongTotal.selector);
        } else if (kind == 2) {
            sigs[index] = _sign(batch[index], 0xBAD);
            expected = abi.encodeWithSelector(Box.BadSignature.selector);
        } else {
            batch[index].toTreasury = type(uint256).max;
            expected = abi.encodeWithSignature("Panic(uint256)", 0x11);
        }
        vm.expectRevert(expected);
        box.settleMany(batch, sigs);
        assertEq(_auditState(keys), beforeState, "batch left partial effects");
        batch[index] = Box.Settlement(keys[index], 1e18, 2e18, 2e18);
        sigs[index] = _sign(batch[index], signerKey);
        box.settleMany(batch, sigs);
        assertEq(usd.balanceOf(address(box)), 0);
        for (uint256 i; i < 4; ++i) {
            (,, bool closed,) = box.orders(keys[i]);
            assertTrue(closed);
        }
    }

    function test_emptyBatchAndClosedEntriesAreHarmless() public {
        bytes32 key = _pay(alice, 1, 0, 0);
        bytes32[] memory keys = _oneKey(key);
        bytes32 beforeState = _auditState(keys);
        vm.recordLogs();
        box.settleMany(new Box.Settlement[](0), new bytes[](0));
        Box.Settlement[] memory batch = new Box.Settlement[](3);
        bytes[] memory sigs = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            batch[i] = Box.Settlement(key, type(uint256).max, 1, 1);
            sigs[i] = hex"abcd";
        }
        box.settleMany(batch, sigs);
        assertEq(vm.getRecordedLogs().length, 0, "skips must not report new settlements");
        assertEq(_auditState(keys), beforeState);
        vm.expectRevert(Box.OrderClosed.selector);
        box.settle(batch[0], sigs[0]);
        vm.expectRevert(Box.WrongTotal.selector);
        box.settleMany(new Box.Settlement[](0), new bytes[](1));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_compromisedSignerCanOnlySplitOneEscrow(uint128 amount, uint128 a, uint128 b) public {
        uint256 escrow = bound(amount, 1, type(uint128).max);
        deal(address(usd), alice, escrow);
        bytes32 key = _pay(alice, 0, 0, escrow);
        bytes32 other = _payOther(31);
        uint256 t = bound(a, 0, escrow);
        uint256 f = bound(b, 0, escrow - t);
        Box.Settlement memory s = Box.Settlement(key, t, f, escrow - t - f);
        bytes memory sig = _sign(s, signerKey);
        uint256 treasuryBefore = usd.balanceOf(treasury);
        uint256 floatBefore = usd.balanceOf(float_);
        uint256 executorBefore = usd.balanceOf(mallory);
        vm.prank(mallory);
        box.settle(s, sig);
        assertEq(usd.balanceOf(treasury) - treasuryBefore, t);
        assertEq(usd.balanceOf(float_) - floatBefore, f);
        assertEq(usd.balanceOf(alice), s.toPayer);
        assertEq(usd.balanceOf(mallory), executorBefore, "executor gained someone else's escrow");
        assertEq(usd.balanceOf(address(box)), 31);
        _assertOrder(other, mallory, uint64(block.timestamp), false, 31);
        _assertOrder(key, alice, uint64(block.timestamp), true, uint128(escrow));
    }

    function test_signerCannotConsumeOtherEscrowEvenWhenBoxHasEnoughBalance() public {
        bytes32 key = _pay(alice, 0, 0, 1);
        _payOther(100);
        Box.Settlement memory s = Box.Settlement(key, 0, 101, 0);
        bytes memory sig = _sign(s, signerKey);
        bytes32[] memory keys = _oneKey(key);
        bytes32 beforeState = _auditState(keys);
        vm.expectRevert(Box.WrongTotal.selector);
        box.settle(s, sig);
        assertEq(_auditState(keys), beforeState);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_malformedSignatureLengthsDoNotConsumeEscrow(uint8 seed) public {
        uint256 length = bound(seed, 0, 128);
        if (length >= 65) ++length; // every length except the only supported length, 65
        bytes32 key = _pay(alice, 0, 0, 17);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 17);
        bytes32[] memory keys = _oneKey(key);
        bytes32 beforeState = _auditState(keys);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, new bytes(length));
        assertEq(_auditState(keys), beforeState);
        box.settle(s, _sign(s, signerKey));
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_zeroRecoveryAndPersonalSignAreRejected() public {
        bytes32 key = _pay(alice, 0, 0, 17);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 17);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, abi.encodePacked(bytes32(0), bytes32(0), uint8(27)));
        bytes32 personalDigest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", BoxSigning.digest(address(box), block.chainid, s))
        );
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(signerKey, personalDigest);
        vm.expectRevert(Box.BadSignature.selector);
        box.settle(s, abi.encodePacked(r, ss, v));
        box.settle(s, _sign(s, signerKey));
    }

    function test_closedOrderIdsNeverReopenAfterEitherExit() public {
        bytes32 key = _pay(alice, 0, 0, 17);
        bytes32 other = _payOther(19);
        Box.Settlement memory s = Box.Settlement(key, 0, 0, 17);
        box.settle(s, _sign(s, signerKey));
        uint64 paidAt = uint64(vm.getBlockTimestamp());
        vm.warp(uint256(paidAt) + 60 days);
        vm.prank(mallory);
        box.reclaim(keccak256("order-2"));
        vm.expectRevert(Box.OrderExists.selector);
        _pay(alice, 1, 0, 1);
        vm.expectRevert(Box.OrderExists.selector);
        _payOther(1);
        _assertOrder(key, alice, paidAt, true, 17);
        _assertOrder(other, mallory, paidAt, true, 19);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_packedFieldsAndReclaimDeadline(uint64 timestamp, uint128 amount) public {
        uint128 escrow = uint128(bound(amount, 1, type(uint128).max));
        deal(address(usd), alice, escrow);
        vm.warp(timestamp);
        bytes32 key = _pay(alice, 0, 0, escrow);
        _assertOrder(key, alice, timestamp, false, escrow);
        // Addition must happen in uint256, even when the deadline exceeds uint64.max.
        uint256 deadline = uint256(timestamp) + 60 days;
        vm.warp(deadline - 1);
        vm.expectRevert(Box.TooEarly.selector);
        vm.prank(alice);
        box.reclaim(ORDER);
        _assertOrder(key, alice, timestamp, false, escrow);
        vm.warp(deadline);
        vm.prank(alice);
        box.reclaim(ORDER);
        _assertOrder(key, alice, timestamp, true, escrow);
        assertEq(usd.balanceOf(alice), escrow);
        assertEq(usd.balanceOf(address(box)), 0);
    }

    function test_maxPackedValuesPreservedWhenDeadlineExceedsUint64() public {
        testFuzz_packedFieldsAndReclaimDeadline(type(uint64).max, type(uint128).max);
    }

    function test_immediatePaymentLegsKeepFullUint256Precision() public {
        uint256 immediate = uint256(type(uint128).max) + 1;
        deal(address(usd), alice, immediate * 2 + 1);
        uint256 beforeFloat = usd.balanceOf(float_);
        uint256 beforeTreasury = usd.balanceOf(treasury);
        vm.expectEmit(true, true, true, true, address(box));
        emit Box.Paid(box.keyOf(alice, ORDER), alice, ORDER, BODY, immediate, immediate, 1, bytes32("ref"));
        bytes32 key = _pay(alice, immediate, immediate, 1);
        assertEq(usd.balanceOf(float_) - beforeFloat, immediate);
        assertEq(usd.balanceOf(treasury) - beforeTreasury, immediate);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(usd.balanceOf(address(box)), 1);
        _assertOrder(key, alice, uint64(block.timestamp), false, 1);
    }

    function test_validSignerCannotPartiallySettleOrWrapTheTotal() public {
        bytes32 key = _pay(alice, 0, 0, 17);
        _payOther(53);
        uint256[4] memory invalidTotals = [uint256(0), 16, 18, 70];
        bytes32[] memory keys = _oneKey(key);
        bytes32 beforeState = _auditState(keys);
        for (uint256 i; i < invalidTotals.length; ++i) {
            Box.Settlement memory s = Box.Settlement(key, invalidTotals[i], 0, 0);
            bytes memory sig = _sign(s, signerKey);
            vm.expectRevert(Box.WrongTotal.selector);
            box.settle(s, sig);
            assertEq(_auditState(keys), beforeState);
        }
        // This would sum to 17 modulo 2**256; checked arithmetic must reject it.
        Box.Settlement memory wrapped = Box.Settlement(key, type(uint256).max, 18, 0);
        bytes memory wrappedSig = _sign(wrapped, signerKey);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        box.settle(wrapped, wrappedSig);
        assertEq(_auditState(keys), beforeState);
    }

    function test_lateBatchTransferFailureRollsBackEarlierOrders() public {
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = _pay(alice, 0, 0, 17);
        keys[1] = _payOther(19);
        Box.Settlement[] memory batch = new Box.Settlement[](2);
        bytes[] memory sigs = new bytes[](2);
        batch[0] = Box.Settlement(keys[0], 1, 2, 14);
        batch[1] = Box.Settlement(keys[1], 3, 4, 12);
        sigs[0] = _sign(batch[0], signerKey);
        sigs[1] = _sign(batch[1], signerKey);
        bytes32 beforeState = _auditState(keys);
        vm.mockCall(address(usd), abi.encodeCall(IERC20.transfer, (mallory, 12)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usd)));
        box.settleMany(batch, sigs);
        assertEq(_auditState(keys), beforeState);
        vm.clearMockedCalls();
        box.settleMany(batch, sigs);
        assertEq(usd.balanceOf(address(box)), 0);
    }
}

/// The same suite against live imdUSD v1 on a mainnet fork (MAINNET_RPC_URL), paying the real Treasury.
contract BoxForkTest is BoxTest {
    IERC20 constant IMDUSD = IERC20(0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25);

    function _token() internal override returns (IERC20) {
        deal(address(IMDUSD), alice, 1_000e18);
        deal(address(IMDUSD), mallory, 1_000e18);
        return IMDUSD;
    }

    function setUp() public override {
        // Skipped, not failed, when MAINNET_RPC_URL is unset, so `forge test` passes with an empty environment.
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        treasury = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc; // imdUSD Treasury
        super.setUp();
    }

    function test_launchDependenciesMatchMainnet() public view {
        assertEq(block.chainid, 1);
        assertGt(address(IMDUSD).code.length, 0);
        assertGt(treasury.code.length, 0);
        assertEq(IERC20Metadata(address(IMDUSD)).decimals(), 18);
        assertEq(address(0xFE0bAC821272c9b905bAc995BF4AF2122b9BA741).code.length, 0);
        assertEq(address(0xB5d3289a90868da0A8d5A4283902a0A907A29ddF).code.length, 0);
        assertEq(address(box.IMDUSD()), address(IMDUSD));
        assertEq(box.TREASURY(), 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc);
    }
}
