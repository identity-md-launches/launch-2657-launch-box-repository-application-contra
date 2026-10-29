// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "../src/Box.sol";
import {MockUsd} from "./Box.t.sol";

/// Drives random interleavings of pay, settle, settleMany (with closed and duplicate entries), reclaim and warp.
contract BoxHandler is Test {
    Box public box;
    MockUsd public usd;
    uint256 public signerKey;
    address[3] public payers;
    bytes32[] public keys;
    mapping(bytes32 => bytes32) public orderIdOf;
    mapping(bytes32 => address) public payerOf;
    uint256 public openEscrow;
    uint256 public ghostTreasury;
    uint256 public ghostFloat;
    uint256 public nonce;

    constructor(Box box_, MockUsd usd_, uint256 signerKey_) {
        box = box_;
        usd = usd_;
        signerKey = signerKey_;
        for (uint256 i; i < 3; ++i) {
            payers[i] = makeAddr(string.concat("payer", vm.toString(i)));
            usd.mint(payers[i], type(uint128).max);
            vm.prank(payers[i]);
            usd.approve(address(box), type(uint256).max);
        }
    }

    function keysLength() external view returns (uint256) {
        return keys.length;
    }

    function pay(uint256 who, uint256 f, uint256 t, uint256 e) external {
        address p = payers[who % 3];
        f = bound(f, 0, 1e24);
        t = bound(t, 0, 1e24);
        e = bound(e, 0, 1e24);
        if (f + t + e == 0) e = 1;
        bytes32 orderId = keccak256(abi.encode(nonce++));
        vm.prank(p);
        bytes32 key = box.pay(orderId, 0, f, t, e, 0);
        keys.push(key);
        orderIdOf[key] = orderId;
        payerOf[key] = p;
        openEscrow += e;
        ghostFloat += f;
        ghostTreasury += t;
    }

    function _sig(Box.Settlement memory s) internal view returns (bytes memory) {
        bytes32 h = keccak256(abi.encode(box.SETTLEMENT_TYPEHASH(), s.key, s.toTreasury, s.toFloat, s.toPayer));
        (uint8 v, bytes32 r, bytes32 ss) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", box.domainSeparator(), h)));
        return abi.encodePacked(r, ss, v);
    }

    function _split(bytes32 key, uint256 a, uint256 b) internal view returns (Box.Settlement memory s) {
        (,,, uint128 escrow) = box.orders(key);
        uint256 x = bound(a, 0, escrow);
        uint256 y = bound(b, 0, escrow - x);
        s = Box.Settlement(key, x, y, escrow - x - y);
    }

    function _close(Box.Settlement memory s) internal {
        openEscrow -= s.toTreasury + s.toFloat + s.toPayer;
        ghostTreasury += s.toTreasury;
        ghostFloat += s.toFloat;
    }

    function settle(uint256 i, uint256 a, uint256 b) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        (,, bool closed,) = box.orders(key);
        Box.Settlement memory s = _split(key, a, b);
        bytes memory sig = _sig(s);
        if (closed) {
            vm.expectRevert(Box.OrderClosed.selector);
            box.settle(s, sig);
            return;
        }
        box.settle(s, sig);
        _close(s);
    }

    function settleMany(uint256 i, uint256 j, uint256 a, uint256 b) external {
        if (keys.length == 0) return;
        Box.Settlement[] memory s = new Box.Settlement[](2);
        bytes[] memory sigs = new bytes[](2);
        s[0] = _split(keys[i % keys.length], a, b);
        s[1] = _split(keys[j % keys.length], b, a);
        sigs[0] = _sig(s[0]);
        sigs[1] = _sig(s[1]);
        (,, bool c0,) = box.orders(s[0].key);
        (,, bool c1,) = box.orders(s[1].key);
        box.settleMany(s, sigs);
        if (!c0) _close(s[0]);
        if (!c1 && s[1].key != s[0].key) _close(s[1]);
    }

    function reclaim(uint256 i) external {
        if (keys.length == 0) return;
        bytes32 key = keys[i % keys.length];
        (, uint64 paidAt, bool closed, uint128 escrow) = box.orders(key);
        if (closed || block.timestamp < uint256(paidAt) + box.RECLAIM_AFTER()) return;
        vm.prank(payerOf[key]);
        box.reclaim(orderIdOf[key]);
        openEscrow -= escrow;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 30 days));
    }
}

contract BoxInvariantTest is Test {
    Box box;
    MockUsd usd;
    BoxHandler handler;
    address treasury = makeAddr("treasury");
    address float_ = makeAddr("float");

    function setUp() public {
        usd = new MockUsd();
        uint256 signerKey = 0xB0B;
        box = new Box(IERC20(address(usd)), treasury, float_, vm.addr(signerKey));
        handler = new BoxHandler(box, usd, signerKey);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_balanceEqualsSumOfOpenEscrow() public view {
        assertEq(usd.balanceOf(address(box)), handler.openEscrow());
        uint256 sum;
        for (uint256 i; i < handler.keysLength(); ++i) {
            (,, bool closed, uint128 escrow) = box.orders(handler.keys(i));
            if (!closed) sum += escrow;
        }
        assertEq(sum, handler.openEscrow());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_recipientsReceiveExactlyGhost() public view {
        assertEq(usd.balanceOf(treasury), handler.ghostTreasury());
        assertEq(usd.balanceOf(float_), handler.ghostFloat());
    }
}
