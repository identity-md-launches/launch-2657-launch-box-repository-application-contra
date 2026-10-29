// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title Box: pay for a swarm request in imdUSD
/// @notice A user pays for an order the evaluator quoted. The cost of the order's first request goes to the float
/// at once (the sender pays the plane from it), the buffer goes to the Treasury, and anything else (a chain's later
/// steps) is held here until the order is settled. The contract checks no prices: the sender sends only orders
/// whose Paid event matches the quote it issued. It has no owner and no power over a user's funds:
/// - a settlement signed by SIGNER can only split one order's escrow among the Treasury, the float and the payer;
/// - an order nobody settled within RECLAIM_AFTER can be reclaimed by its payer, so funds cannot be stuck here.
/// Orders are keyed by (payer, orderId), so nobody can take another wallet's order id from the mempool.
contract Box is EIP712 {
    using SafeERC20 for IERC20;

    IERC20 public immutable IMDUSD;
    address public immutable TREASURY;
    address public immutable FLOAT;
    address public immutable SIGNER;

    uint256 public constant RECLAIM_AFTER = 60 days;

    bytes32 public constant SETTLEMENT_TYPEHASH =
        keccak256("Settlement(bytes32 key,uint256 toTreasury,uint256 toFloat,uint256 toPayer)");

    struct Order {
        address payer;
        uint64 paidAt;
        bool closed; // settled or reclaimed
        uint128 escrow;
    }

    struct Settlement {
        bytes32 key;
        uint256 toTreasury;
        uint256 toFloat;
        uint256 toPayer;
    }

    mapping(bytes32 key => Order) public orders;

    event Paid(
        bytes32 indexed key,
        address indexed payer,
        bytes32 indexed orderId,
        bytes32 commitment,
        uint256 toFloat,
        uint256 toTreasury,
        uint256 escrow,
        bytes32 ref
    );
    event Settled(bytes32 indexed key, uint256 toTreasury, uint256 toFloat, uint256 toPayer);
    event Reclaimed(bytes32 indexed key, address indexed payer, uint256 amount);

    error ZeroAddress();
    error OrderExists();
    error NothingPaid();
    error EscrowTooLarge();
    error UnknownOrder();
    error OrderClosed();
    error WrongTotal();
    error BadSignature();
    error TooEarly();

    constructor(IERC20 imdUsd, address treasury, address float_, address signer) EIP712("Box", "1") {
        if (address(imdUsd) == address(0) || treasury == address(0) || float_ == address(0) || signer == address(0)) {
            revert ZeroAddress();
        }
        IMDUSD = imdUsd;
        TREASURY = treasury;
        FLOAT = float_;
        SIGNER = signer;
    }

    /// @notice The key an order is stored under.
    function keyOf(address payer, bytes32 orderId) public pure returns (bytes32) {
        return keccak256(abi.encode(payer, orderId));
    }

    /// @notice Pay for an order. Pulls toFloat + toTreasury + escrow imdUSD from the caller (approve first).
    /// @param orderId the evaluator's order id
    /// @param commitment keccak256 of the request body that will be sent, so a wrong send is provable
    /// @param toFloat the cost of the first request, to the float now
    /// @param toTreasury the buffer, to the Treasury now
    /// @param escrow held here until the order is settled (a chain's later steps); may be zero
    /// @param ref attribution only; not used by the contract
    function pay(bytes32 orderId, bytes32 commitment, uint256 toFloat, uint256 toTreasury, uint256 escrow, bytes32 ref)
        external
        returns (bytes32 key)
    {
        if (toFloat + toTreasury + escrow == 0) revert NothingPaid();
        if (escrow > type(uint128).max) revert EscrowTooLarge();
        key = keyOf(msg.sender, orderId);
        if (orders[key].payer != address(0)) revert OrderExists();
        orders[key] =
            Order({payer: msg.sender, paidAt: uint64(block.timestamp), closed: escrow == 0, escrow: uint128(escrow)});

        if (toFloat != 0) IMDUSD.safeTransferFrom(msg.sender, FLOAT, toFloat);
        if (toTreasury != 0) IMDUSD.safeTransferFrom(msg.sender, TREASURY, toTreasury);
        if (escrow != 0) IMDUSD.safeTransferFrom(msg.sender, address(this), escrow);

        emit Paid(key, msg.sender, orderId, commitment, toFloat, toTreasury, escrow, ref);
    }

    /// @notice Execute a settlement signed by SIGNER. Anyone may call it (a user executes their own refund).
    function settle(Settlement calldata s, bytes calldata signature) public {
        Order storage o = orders[s.key];
        if (o.payer == address(0)) revert UnknownOrder();
        if (o.closed) revert OrderClosed();
        if (s.toTreasury + s.toFloat + s.toPayer != o.escrow) revert WrongTotal();
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(SETTLEMENT_TYPEHASH, s.key, s.toTreasury, s.toFloat, s.toPayer)));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != SIGNER) revert BadSignature();

        o.closed = true;
        address payer = o.payer;
        if (s.toTreasury != 0) IMDUSD.safeTransfer(TREASURY, s.toTreasury);
        if (s.toFloat != 0) IMDUSD.safeTransfer(FLOAT, s.toFloat);
        if (s.toPayer != 0) IMDUSD.safeTransfer(payer, s.toPayer);
        emit Settled(s.key, s.toTreasury, s.toFloat, s.toPayer);
    }

    /// @notice Execute many settlements in one transaction (the keeper's weekly run). An entry whose order is already
    /// closed (reclaimed, settled ahead of the batch, or repeated in it) is skipped; reverts if any other entry fails.
    function settleMany(Settlement[] calldata s, bytes[] calldata signatures) external {
        if (s.length != signatures.length) revert WrongTotal();
        for (uint256 i; i < s.length; ++i) {
            Order storage o = orders[s[i].key];
            if (o.payer != address(0) && o.closed) continue;
            settle(s[i], signatures[i]);
        }
    }

    /// @notice The payer takes back an order's escrow if nobody settled it within RECLAIM_AFTER of payment.
    function reclaim(bytes32 orderId) external {
        bytes32 key = keyOf(msg.sender, orderId);
        Order storage o = orders[key];
        if (o.payer == address(0)) revert UnknownOrder();
        if (o.closed) revert OrderClosed();
        if (block.timestamp < uint256(o.paidAt) + RECLAIM_AFTER) revert TooEarly();
        o.closed = true;
        uint256 amount = o.escrow;
        IMDUSD.safeTransfer(msg.sender, amount);
        emit Reclaimed(key, msg.sender, amount);
    }

    /// @notice The EIP-712 domain separator, for the sender's signer.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
