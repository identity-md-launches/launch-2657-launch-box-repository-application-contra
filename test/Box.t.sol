// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Box} from "../src/Box.sol";

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
        bytes32 h = keccak256(abi.encode(box.SETTLEMENT_TYPEHASH(), s.key, s.toTreasury, s.toFloat, s.toPayer));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", box.domainSeparator(), h));
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
        vm.prank(mallory); // anyone may execute
        box.settle(s, _sign(s, signerKey));
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
        vm.warp(block.timestamp + 60 days - 1);
        vm.prank(alice);
        vm.expectRevert(Box.TooEarly.selector);
        box.reclaim(ORDER);
        vm.warp(block.timestamp + 1);
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
}
