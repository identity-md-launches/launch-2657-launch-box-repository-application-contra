// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Box} from "src/Box.sol";

/// An operator-side encoding oracle: never reads Box's type hash or domain separator.
library BoxSigning {
    function domain(address verifyingContract, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Box"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
    }

    function digest(address verifyingContract, uint256 chainId, Box.Settlement memory s)
        internal
        pure
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Settlement(bytes32 key,uint256 toTreasury,uint256 toFloat,uint256 toPayer)"),
                s.key,
                s.toTreasury,
                s.toFloat,
                s.toPayer
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain(verifyingContract, chainId), structHash));
    }
}
