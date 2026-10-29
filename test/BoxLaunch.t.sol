// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Box} from "src/Box.sol";
import {BoxSigning} from "./helpers/BoxSigning.sol";

contract BoxLaunchProbe {
    function deploy(bytes memory code, bytes32 salt, uint256 value) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(value, add(code, 32), mload(code), salt)
        }
    }
}

contract BoxLaunchTest is Test {
    address private constant IMDUSD = 0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25;
    address private constant TREASURY = 0x6Ac8fF96Fb8DCF5d79A8eF1E59D9AC23f2BD27Bc;
    address private constant FLOAT = 0xFE0bAC821272c9b905bAc995BF4AF2122b9BA741;
    address private constant SIGNER = 0xB5d3289a90868da0A8d5A4283902a0A907A29ddF;

    function _creationCode() internal pure returns (bytes memory) {
        return abi.encodePacked(type(Box).creationCode, abi.encode(IMDUSD, TREASURY, FLOAT, SIGNER));
    }

    function test_approvedStaticArgumentsDeployFromFactoryOnEmptyChain() public {
        vm.chainId(1);
        assertEq(IMDUSD.code.length, 0);
        assertEq(TREASURY.code.length, 0);
        assertEq(FLOAT.code.length, 0);
        assertEq(SIGNER.code.length, 0);
        BoxLaunchProbe factory = new BoxLaunchProbe();
        bytes memory code = _creationCode();
        bytes32 salt = keccak256("Box application launch");
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, keccak256(code))))));
        // No dependency or recipient can be called by the constructor, even on an empty chain.
        vm.expectCall(IMDUSD, bytes(""), uint64(0));
        vm.expectCall(TREASURY, bytes(""), uint64(0));
        vm.expectCall(FLOAT, bytes(""), uint64(0));
        vm.expectCall(SIGNER, bytes(""), uint64(0));
        Box launched = Box(factory.deploy(code, salt, 0));
        assertEq(address(launched), expected);
        assertGt(address(launched).code.length, 0);
        assertLe(address(launched).code.length, 24_576);
        assertLe(code.length, 49_152);
        assertEq(address(launched.IMDUSD()), IMDUSD);
        assertEq(launched.TREASURY(), TREASURY);
        assertEq(launched.FLOAT(), FLOAT);
        assertEq(launched.SIGNER(), SIGNER);
        assertEq(launched.RECLAIM_AFTER(), 60 days);
        assertEq(launched.domainSeparator(), BoxSigning.domain(address(launched), 1));
    }

    function test_eachZeroConstructorArgumentIsRejected() public {
        for (uint256 i; i < 4; ++i) {
            address[4] memory args = [IMDUSD, TREASURY, FLOAT, SIGNER];
            args[i] = address(0);
            vm.expectRevert(Box.ZeroAddress.selector);
            new Box(IERC20(args[0]), args[1], args[2], args[3]);
        }
    }

    function test_emptyChainTokenIsRejectedOnFirstUseWithoutCreatingAnOrder() public {
        Box box = new Box(IERC20(IMDUSD), TREASURY, FLOAT, SIGNER);
        bytes32 id = keccak256("unfunded on empty chain");
        bytes32 key = keccak256(abi.encode(address(this), id));
        vm.expectRevert(abi.encodeWithSignature("AddressEmptyCode(address)", IMDUSD));
        box.pay(id, 0, 1, 0, 0, 0);
        (address payer, uint64 at, bool closed, uint128 escrow) = box.orders(key);
        assertEq(payer, address(0));
        assertEq(at, 0);
        assertFalse(closed);
        assertEq(escrow, 0);
    }

    function test_deploymentAndPublicEntrypointsRejectNativeValue() public {
        BoxLaunchProbe factory = new BoxLaunchProbe();
        vm.deal(address(factory), 1);
        assertEq(factory.deploy(_creationCode(), keccak256("nonpayable"), 1), address(0));
        assertEq(address(factory).balance, 1);
        Box box = new Box(IERC20(IMDUSD), TREASURY, FLOAT, SIGNER);
        vm.deal(address(this), 2);
        (bool sent,) = address(box).call{value: 1}("");
        assertFalse(sent);
        (bool paid,) =
            address(box).call{value: 1}(abi.encodeCall(Box.pay, (bytes32(0), bytes32(0), 1, 0, 0, bytes32(0))));
        assertFalse(paid);
        assertEq(address(box).balance, 0);
    }

    function test_factoryAndSignerHaveNoAdministrativeEntrypoints() public {
        BoxLaunchProbe factory = new BoxLaunchProbe();
        Box box = Box(factory.deploy(_creationCode(), keccak256("no admin"), 0));
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("owner()");
        calls[1] = abi.encodeWithSignature("pause()");
        calls[2] = abi.encodeWithSignature("transferOwnership(address)", SIGNER);
        calls[3] = abi.encodeWithSignature("setSigner(address)", FLOAT);
        calls[4] = abi.encodeWithSignature("setTreasury(address)", FLOAT);
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", address(factory));
        calls[6] = abi.encodeWithSignature("sweep(address,address,uint256)", IMDUSD, SIGNER, 1);
        for (uint256 actor; actor < 2; ++actor) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(actor == 0 ? address(factory) : SIGNER);
                (bool ok,) = address(box).call(calls[i]);
                assertFalse(ok, "unexpected administration surface");
            }
        }
        assertEq(box.TREASURY(), TREASURY);
        assertEq(box.FLOAT(), FLOAT);
        assertEq(box.SIGNER(), SIGNER);
    }
}
