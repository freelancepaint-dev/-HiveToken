// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken - Testnet V1

    Fixed Supply: 1,000,000 tokens
    Owner Allocation: 15%
    Liquidity Allocation: 85%

    V1 intentionally contains no trading tax.
    Tax/Hive funding will be added after the basic
    token has been tested successfully.
*/

contract HiveToken {

    string public name = "Hive Token";
    string public symbol = "HIVE";
    uint8 public constant decimals = 18;

    uint256 public constant totalSupply = 1_000_000 * 10**18;

    uint256 public constant OWNER_ALLOCATION = 150_000 * 10**18;
    uint256 public constant LIQUIDITY_ALLOCATION = 850_000 * 10**18;

    address public immutable owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor() {
        owner = msg.sender;

        // All tokens initially go to the deployer.
        // 150,000 are the owner's allocation.
        // 850,000 are reserved for adding liquidity.
        balanceOf[msg.sender] = totalSupply;

        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];

        require(allowed >= amount, "Allowance exceeded");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }

        _transfer(from, to, amount);

        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        require(to != address(0), "Zero address");
        require(balanceOf[from] >= amount, "Insufficient balance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit Transfer(from, to, amount);
    }
}
