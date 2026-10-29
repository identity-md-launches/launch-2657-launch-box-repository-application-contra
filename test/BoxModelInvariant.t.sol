// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "src/Box.sol";
import {MockUsd} from "./Box.t.sol";
import {BoxSigning} from "./helpers/BoxSigning.sol";

/// Independent ledger: no successful transition is inferred from Box.orders or its token balance.
contract BoxModelHandler is Test {
    struct ExpectedOrder {
        bytes32 key;
        bytes32 id;
        address payer;
        uint64 paidAt;
        uint128 escrow;
        bool closed;
        uint256 paidOut;
    }

    Box public immutable box;
    MockUsd public immutable usd;
    address public immutable treasury;
    address public immutable floatWallet;
    address public immutable executor;
    uint256 private immutable signingKey;
    uint256 public constant INITIAL_BALANCE = 1 << 200;

    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(bytes32 => uint256) private indexPlusOne;
    ExpectedOrder[] private expectedOrders;
    uint256 public openEscrow;
    uint256 public donations;
    uint256 public successfulPays;
    uint256 public successfulSettles;
    uint256 public successfulReclaims;
    uint256 public rejectedCalls;
    uint256 private roundTripNonce;

    constructor(Box box_, MockUsd usd_, uint256 key_) {
        box = box_;
        usd = usd_;
        signingKey = key_;
        treasury = box_.TREASURY();
        floatWallet = box_.FLOAT();
        executor = makeAddr("model executor with no orders");
        actors = [makeAddr("model alice"), makeAddr("model bob"), makeAddr("model carol"), treasury, floatWallet];
        for (uint256 i; i < actors.length; ++i) {
            usd.mint(actors[i], INITIAL_BALANCE);
            expectedBalance[actors[i]] = INITIAL_BALANCE;
            vm.prank(actors[i]);
            usd.approve(address(box), type(uint256).max);
        }
    }

    function _signature(Box.Settlement memory s, uint256 key, address verifyingContract, uint256 chain)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 ss) = vm.sign(key, BoxSigning.digest(verifyingContract, chain, s));
        return abi.encodePacked(r, ss, v);
    }

    function _signature(Box.Settlement memory s) internal view returns (bytes memory) {
        return _signature(s, signingKey, address(box), block.chainid);
    }

    function _pay(address payer, bytes32 id, uint256 f, uint256 t, uint256 e) internal {
        bytes32 key = keccak256(abi.encode(payer, id));
        if (f + t + e == 0 || indexPlusOne[key] != 0) {
            vm.expectRevert(f + t + e == 0 ? Box.NothingPaid.selector : Box.OrderExists.selector);
            vm.prank(payer);
            box.pay(id, keccak256("model quote"), f, t, e, 0);
            ++rejectedCalls;
            return;
        }
        vm.prank(payer);
        assertEq(box.pay(id, keccak256("model quote"), f, t, e, 0), key);
        expectedOrders.push(ExpectedOrder(key, id, payer, uint64(block.timestamp), uint128(e), e == 0, 0));
        indexPlusOne[key] = expectedOrders.length;
        expectedBalance[payer] -= f + t + e;
        expectedBalance[floatWallet] += f;
        expectedBalance[treasury] += t;
        openEscrow += e;
        ++successfulPays;
    }

    function pay(uint256 actorSeed, uint256 idSeed, uint128 f, uint128 t, uint128 e) external {
        // Reused ids deliberately collide within a payer and coexist across payers.
        _pay(actors[actorSeed % actors.length], bytes32(idSeed % 32), bound(f, 0, 1e24), bound(t, 0, 1e24), e);
    }

    function _split(uint256 index, uint256 a, uint256 b) internal view returns (Box.Settlement memory s) {
        ExpectedOrder storage order = expectedOrders[index];
        uint256 t = bound(a, 0, order.escrow);
        uint256 f = bound(b, 0, uint256(order.escrow) - t);
        return Box.Settlement(order.key, t, f, uint256(order.escrow) - t - f);
    }

    function _close(uint256 index, Box.Settlement memory s) internal {
        ExpectedOrder storage order = expectedOrders[index];
        assertFalse(order.closed, "harness attempted a second payout");
        order.closed = true;
        order.paidOut += uint256(order.escrow);
        openEscrow -= order.escrow;
        expectedBalance[treasury] += s.toTreasury;
        expectedBalance[floatWallet] += s.toFloat;
        expectedBalance[order.payer] += s.toPayer;
    }

    function settle(uint256 indexSeed, uint256 a, uint256 b, uint256 callerSeed) external {
        if (expectedOrders.length == 0) return;
        uint256 index = indexSeed % expectedOrders.length;
        Box.Settlement memory s = _split(index, a, b);
        bytes memory sig = _signature(s);
        address caller = callerSeed % 2 == 0 ? executor : actors[callerSeed % actors.length];
        if (expectedOrders[index].closed) {
            vm.expectRevert(Box.OrderClosed.selector);
            vm.prank(caller);
            box.settle(s, sig);
            ++rejectedCalls;
        } else {
            vm.prank(caller);
            box.settle(s, sig);
            _close(index, s);
            ++successfulSettles;
        }
    }

    function settleMany(uint256 firstSeed, uint256 secondSeed, uint256 a, uint256 b) external {
        if (expectedOrders.length == 0) return;
        uint256 first = firstSeed % expectedOrders.length;
        uint256 second = secondSeed % expectedOrders.length;
        uint256[4] memory indexes = [first, second, first, second];
        Box.Settlement[] memory batch = new Box.Settlement[](4);
        bytes[] memory sigs = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            // Duplicate keys can carry DIFFERENT signed splits; only the first open occurrence pays.
            batch[i] = _split(indexes[i], i % 2 == 0 ? a : b, i < 2 ? b : a);
            sigs[i] = _signature(batch[i]);
        }
        vm.prank(executor);
        box.settleMany(batch, sigs);
        for (uint256 i; i < 4; ++i) {
            if (!expectedOrders[indexes[i]].closed) {
                _close(indexes[i], batch[i]);
                ++successfulSettles;
            }
        }
    }

    function _openIndex(uint256 seed) internal view returns (bool found, uint256 index) {
        if (expectedOrders.length == 0) return (false, 0);
        for (uint256 i; i < expectedOrders.length; ++i) {
            index = (seed % expectedOrders.length + i) % expectedOrders.length;
            if (!expectedOrders[index].closed) return (true, index);
        }
        return (false, 0);
    }

    function invalidSettlement(uint256 seed, uint8 failure) external {
        (bool found, uint256 index) = _openIndex(seed);
        if (!found) return;
        ExpectedOrder storage order = expectedOrders[index];
        Box.Settlement memory s = Box.Settlement(order.key, 0, 0, order.escrow);
        bytes memory sig = _signature(s);
        bytes memory expected = abi.encodeWithSelector(Box.BadSignature.selector);
        uint256 kind = failure % 7;
        if (kind == 0) {
            sig = _signature(s, signingKey + 1, address(box), block.chainid);
        } else if (kind == 1) {
            sig = hex"abcd";
        } else if (kind == 2) {
            sig = _signature(s, signingKey, address(box), block.chainid + 1);
        } else if (kind == 3) {
            sig = _signature(s, signingKey, address(this), block.chainid);
        } else if (kind == 4) {
            ++s.toPayer;
            expected = abi.encodeWithSelector(Box.WrongTotal.selector);
        } else if (kind == 5) {
            s.toTreasury = type(uint256).max;
            expected = abi.encodeWithSignature("Panic(uint256)", 0x11);
        } else {
            // The total is still right, but the authorization was for a different allocation.
            s.toTreasury = 1;
            --s.toPayer;
        }
        vm.expectRevert(expected);
        vm.prank(executor);
        box.settle(s, sig);
        ++rejectedCalls;
    }

    function invalidBatch(uint256 seed) external {
        (bool found, uint256 index) = _openIndex(seed);
        if (!found) return;
        Box.Settlement[] memory batch = new Box.Settlement[](2);
        bytes[] memory sigs = new bytes[](2);
        batch[0] = _split(index, 1, 1);
        sigs[0] = _signature(batch[0]);
        batch[1] = Box.Settlement(keccak256("not an order key"), 0, 0, 0);
        sigs[1] = _signature(batch[1]);
        vm.expectRevert(Box.UnknownOrder.selector);
        vm.prank(executor);
        box.settleMany(batch, sigs);
        ++rejectedCalls;
        // The independent model remains unchanged; all invariants run after this rejected batch.
    }

    function reclaim(uint256 idSeed, uint256 callerSeed) external {
        if (expectedOrders.length == 0) return;
        bytes32 id = expectedOrders[idSeed % expectedOrders.length].id;
        address caller = callerSeed % 6 == 5 ? executor : actors[callerSeed % actors.length];
        bytes32 key = keccak256(abi.encode(caller, id));
        uint256 position = indexPlusOne[key];
        if (position == 0) {
            vm.expectRevert(Box.UnknownOrder.selector);
            vm.prank(caller);
            box.reclaim(id);
            ++rejectedCalls;
            return;
        }
        ExpectedOrder storage order = expectedOrders[position - 1];
        if (order.closed || block.timestamp < uint256(order.paidAt) + 60 days) {
            vm.expectRevert(order.closed ? Box.OrderClosed.selector : Box.TooEarly.selector);
            vm.prank(caller);
            box.reclaim(id);
            ++rejectedCalls;
            return;
        }
        _reclaim(position - 1);
    }

    function _reclaim(uint256 index) internal {
        ExpectedOrder storage order = expectedOrders[index];
        vm.prank(order.payer);
        box.reclaim(order.id);
        _close(index, Box.Settlement(order.key, 0, 0, order.escrow));
        ++successfulReclaims;
    }

    function replayClosed(uint256 seed) external {
        if (expectedOrders.length == 0) return;
        uint256 index = seed % expectedOrders.length;
        ExpectedOrder storage order = expectedOrders[index];
        if (!order.closed) return;
        Box.Settlement memory s = _split(index, 0, 0);
        bytes memory sig = _signature(s);
        vm.expectRevert(Box.OrderClosed.selector);
        box.settle(s, sig);
        vm.expectRevert(Box.OrderClosed.selector);
        vm.prank(order.payer);
        box.reclaim(order.id);
        vm.expectRevert(Box.OrderExists.selector);
        vm.prank(order.payer);
        box.pay(order.id, 0, 0, 0, 1, 0);
        rejectedCalls += 3;
    }

    function payWithoutAllowance(uint256 actorSeed) external {
        address payer = actors[actorSeed % actors.length];
        vm.prank(payer);
        usd.approve(address(box), 0);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", address(box), 0, 1)
        );
        vm.prank(payer);
        box.pay(keccak256("never successfully funded"), 0, 1, 1, 1, 0);
        (address recordedPayer, uint64 paidAt, bool closed, uint128 escrow) =
            box.orders(keccak256(abi.encode(payer, keccak256("never successfully funded"))));
        assertEq(recordedPayer, address(0), "failed pay left a phantom order");
        assertEq(paidAt, 0);
        assertFalse(closed);
        assertEq(escrow, 0);
        vm.prank(payer);
        usd.approve(address(box), type(uint256).max);
        ++rejectedCalls;
    }

    function donate(uint256 actorSeed, uint128 amount) external {
        address donor = actors[actorSeed % actors.length];
        vm.prank(donor);
        assertTrue(usd.transfer(address(box), amount));
        expectedBalance[donor] -= amount;
        donations += amount;
    }

    function roundTrip(uint256 actorSeed, uint128 amount) external {
        address payer = actors[actorSeed % actors.length];
        uint256 escrow = bound(amount, 1, type(uint128).max);
        uint256 beforeBalance = usd.balanceOf(payer);
        bytes32 id = bytes32((uint256(1) << 255) | roundTripNonce++);
        _pay(payer, id, 0, 0, escrow);
        uint256 index = expectedOrders.length - 1;
        Box.Settlement memory s = _split(index, 0, 0);
        bytes memory sig = _signature(s);
        vm.prank(executor);
        box.settle(s, sig);
        _close(index, s);
        ++successfulSettles;
        assertEq(usd.balanceOf(payer), beforeBalance, "pay/refund round trip created or lost value");
    }

    function advanceTime(uint256 elapsed) external {
        vm.warp(block.timestamp + bound(elapsed, 0, 90 days));
    }

    function assertSolventAndConserved() external view {
        uint256 sum;
        for (uint256 i; i < expectedOrders.length; ++i) {
            if (!expectedOrders[i].closed) sum += expectedOrders[i].escrow;
        }
        assertEq(sum, openEscrow, "independent order obligations disagree");
        assertEq(usd.balanceOf(address(box)), sum + donations, "Box assets do not cover escrow plus donations");
        uint256 held = usd.balanceOf(address(box));
        for (uint256 i; i < actors.length; ++i) {
            assertEq(usd.balanceOf(actors[i]), expectedBalance[actors[i]], "wrong recipient or amount");
            held += usd.balanceOf(actors[i]);
        }
        assertEq(usd.balanceOf(executor), 0, "permissionless execution paid an unrelated wallet");
        assertEq(held, INITIAL_BALANCE * actors.length, "value left the tracked recipients");
        assertEq(usd.totalSupply(), INITIAL_BALANCE * actors.length, "supply changed");
    }

    function assertOrderLifecycle() external view {
        for (uint256 i; i < expectedOrders.length; ++i) {
            ExpectedOrder storage order = expectedOrders[i];
            (address payer, uint64 at, bool closed, uint128 escrow) = box.orders(order.key);
            assertEq(payer, order.payer, "payer was overwritten");
            assertEq(at, order.paidAt, "payment timestamp was overwritten");
            assertEq(escrow, order.escrow, "original escrow was overwritten");
            assertEq(closed, order.closed, "order reopened or failed to close");
            assertEq(
                order.paidOut, order.closed ? order.escrow : 0, "an order paid out more or less than its own escrow"
            );
        }
        assertEq(box.TREASURY(), treasury);
        assertEq(box.FLOAT(), floatWallet);
        assertEq(box.SIGNER(), vm.addr(signingKey));
        assertEq(address(box.IMDUSD()), address(usd));
    }

    /// Called only after a campaign, not selected by the invariant fuzzer.
    function finishAndCheckWithdrawalLiveness() external {
        vm.warp(block.timestamp + 60 days);
        for (uint256 i; i < expectedOrders.length; ++i) {
            if (!expectedOrders[i].closed) _reclaim(i);
        }
        assertEq(openEscrow, 0, "an escrow could not be reclaimed");
        assertEq(usd.balanceOf(address(box)), donations, "open escrow stranded after every payer exited");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract BoxModelInvariantTest is Test {
    BoxModelHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        MockUsd usd = new MockUsd();
        uint256 signerKey = 0xB0B;
        Box box = new Box(IERC20(address(usd)), makeAddr("model treasury"), makeAddr("model float"), vm.addr(signerKey));
        handler = new BoxModelHandler(box, usd, signerKey);
        // Nonempty initial state includes reused ids across different payers and both open/closed orders.
        handler.pay(0, 0, 11, 13, 17);
        handler.pay(1, 0, 0, 0, type(uint128).max);
        handler.pay(2, 1, 1, 0, 0);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.pay.selector;
        selectors[1] = handler.settle.selector;
        selectors[2] = handler.settleMany.selector;
        selectors[3] = handler.reclaim.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.invalidSettlement.selector;
        selectors[6] = handler.invalidBatch.selector;
        selectors[7] = handler.replayClosed.selector;
        selectors[8] = handler.payWithoutAllowance.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_balancesFollowIndependentLedger() public view {
        handler.assertSolventAndConserved();
    }

    function invariant_ordersAreImmutableAndCloseExactlyOnce() public view {
        handler.assertOrderLifecycle();
    }

    function afterInvariant() public {
        handler.finishAndCheckWithdrawalLiveness();
        handler.assertSolventAndConserved();
        handler.assertOrderLifecycle();
    }

    function test_modelExercisesRejectionsRecipientsAndBothExits() public {
        handler.pay(0, 0, 1, 1, 1); // duplicate
        handler.pay(0, 3, 0, 0, 0); // nothing paid
        for (uint8 i; i < 7; ++i) {
            handler.invalidSettlement(0, i);
        }
        handler.invalidBatch(0);
        handler.payWithoutAllowance(0);
        handler.reclaim(0, 0); // too early
        handler.reclaim(0, 5); // not the payer
        handler.settle(0, 3, 5, 0);
        handler.replayClosed(0);
        handler.advanceTime(60 days);
        handler.reclaim(1, 1);
        handler.pay(3, 2, 1, 2, 31); // Treasury as payer, including a self-transfer
        handler.pay(4, 2, 2, 1, 37); // FLOAT as payer
        handler.settleMany(3, 4, 11, 13);
        handler.donate(0, 41);
        handler.roundTrip(4, type(uint128).max);
        assertGt(handler.successfulPays(), 0);
        assertGt(handler.successfulSettles(), 0);
        assertGt(handler.successfulReclaims(), 0);
        assertGt(handler.rejectedCalls(), 0);
        handler.assertSolventAndConserved();
        handler.assertOrderLifecycle();
        afterInvariant();
    }
}
