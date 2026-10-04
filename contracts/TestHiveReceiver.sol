// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken V4 Test Receiver

    TESTNET ONLY.

    Mimics the payable function HiveToken V4
    will call on the real BnBeeHive contract.
*/

contract TestHiveReceiver {

    uint256 public totalReceived;

    uint256 public callCount;

    address public lastCaller;

    address public lastReferral;

    uint256 public lastAmount;

    event BuyEggsReceived(
        address indexed caller,
        address indexed referral,
        uint256 amount
    );

    function buyEggs(
        address ref
    )
        external
        payable
    {
        require(
            msg.value > 0,
            "No BNB received"
        );

        totalReceived +=
            msg.value;

        callCount +=
            1;

        lastCaller =
            msg.sender;

        lastReferral =
            ref;

        lastAmount =
            msg.value;

        emit BuyEggsReceived(
            msg.sender,
            ref,
            msg.value
        );
    }
}
