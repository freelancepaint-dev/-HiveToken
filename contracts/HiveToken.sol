// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken - Tax Testnet V3

    Fixed Supply: 1,000,000 HIVE
    Buy Tax: 2.5%
    Sell Tax: 2.5%
    Wallet transfers: 0%

    Tax flow:
    HIVE tax -> contract -> swap to BNB -> Hive funding address

    Pair setup:
    1. Deploy token
    2. Create/find HIVE/WBNB pair
    3. Owner calls setPair(pairAddress) ONCE
    4. Pair can never be changed again

    TESTNET FIRST.
*/

interface IPancakeRouter {
    function WETH() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract HiveToken {

    string public constant name = "Hive Token";
    string public constant symbol = "HIVE";
    uint8 public constant decimals = 18;

    uint256 public constant totalSupply =
        1_000_000 * 10**18;

    uint256 public constant OWNER_ALLOCATION =
        150_000 * 10**18;

    uint256 public constant LIQUIDITY_ALLOCATION =
        850_000 * 10**18;

    uint256 public constant BUY_TAX = 250;
    uint256 public constant SELL_TAX = 250;
    uint256 public constant TAX_DENOMINATOR = 10_000;

    address public immutable owner;
    address payable public immutable hiveAddress;

    IPancakeRouter public immutable router;

    address public pair;
    bool public pairLocked;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256))
        public allowance;

    mapping(address => bool) public isTaxExempt;

    bool private swapping;

    uint256 public constant swapThreshold =
        100 * 10**18;

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

    event PairConfigured(
        address indexed pair
    );

    event TaxCollected(
        address indexed from,
        uint256 amount
    );

    event HiveFunded(
        uint256 hiveSwapped,
        uint256 bnbSent
    );

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "Not owner"
        );
        _;
    }

    constructor(
        address routerAddress,
        address payable hiveFundingAddress
    ) {

        require(
            routerAddress != address(0),
            "Zero router"
        );

        require(
            hiveFundingAddress != address(0),
            "Zero Hive address"
        );

        owner = msg.sender;

        router =
            IPancakeRouter(routerAddress);

        hiveAddress =
            hiveFundingAddress;

        isTaxExempt[msg.sender] = true;
        isTaxExempt[address(this)] = true;

        balanceOf[msg.sender] =
            totalSupply;

        emit Transfer(
            address(0),
            msg.sender,
            totalSupply
        );
    }

    receive() external payable {}

    /*
        ONE-TIME PAIR CONFIGURATION

        Once set successfully, pairLocked becomes true
        and the pair can never be changed again.
    */
    function setPair(
        address pairAddress
    ) external onlyOwner {

        require(
            !pairLocked,
            "Pair already locked"
        );

        require(
            pairAddress != address(0),
            "Zero pair"
        );

        pair = pairAddress;
        pairLocked = true;

        emit PairConfigured(
            pairAddress
        );
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {

        _transfer(
            msg.sender,
            to,
            amount
        );

        return true;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {

        allowance[msg.sender][spender] =
            amount;

        emit Approval(
            msg.sender,
            spender,
            amount
        );

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {

        uint256 allowed =
            allowance[from][msg.sender];

        require(
            allowed >= amount,
            "Allowance exceeded"
        );

        if (
            allowed != type(uint256).max
        ) {

            allowance[from][msg.sender] =
                allowed - amount;

            emit Approval(
                from,
                msg.sender,
                allowance[from][msg.sender]
            );
        }

        _transfer(
            from,
            to,
            amount
        );

        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {

        require(
            from != address(0),
            "Zero sender"
        );

        require(
            to != address(0),
            "Zero address"
        );

        require(
            balanceOf[from] >= amount,
            "Insufficient balance"
        );

        /*
            Convert accumulated tax on a subsequent sell
            once at least 100 HIVE is already accumulated.
        */
        if (
            pairLocked &&
            to == pair &&
            !swapping &&
            balanceOf[address(this)] >=
                swapThreshold
        ) {
            _swapTaxForBNB();
        }

        uint256 taxAmount = 0;

        if (
            pairLocked &&
            !swapping &&
            !isTaxExempt[from] &&
            !isTaxExempt[to]
        ) {

            // BUY
            if (from == pair) {

                taxAmount =
                    (amount * BUY_TAX) /
                    TAX_DENOMINATOR;
            }

            // SELL
            else if (to == pair) {

                taxAmount =
                    (amount * SELL_TAX) /
                    TAX_DENOMINATOR;
            }
        }

        uint256 sendAmount =
            amount - taxAmount;

        balanceOf[from] -=
            amount;

        balanceOf[to] +=
            sendAmount;

        emit Transfer(
            from,
            to,
            sendAmount
        );

        if (taxAmount > 0) {

            balanceOf[address(this)] +=
                taxAmount;

            emit Transfer(
                from,
                address(this),
                taxAmount
            );

            emit TaxCollected(
                from,
                taxAmount
            );
        }
    }

    function _swapTaxForBNB()
        internal
    {

        uint256 tokenAmount =
            balanceOf[address(this)];

        if (tokenAmount == 0) {
            return;
        }

        swapping = true;

        allowance[address(this)]
            [address(router)] =
            tokenAmount;

        emit Approval(
            address(this),
            address(router),
            tokenAmount
        );

        address[] memory path =
            new address[](2);

        path[0] =
            address(this);

        path[1] =
            router.WETH();

        uint256 balanceBefore =
            address(this).balance;

        router
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                0,
                path,
                address(this),
                block.timestamp
            );

        uint256 bnbReceived =
            address(this).balance -
            balanceBefore;

        if (bnbReceived > 0) {

            (bool success, ) =
                hiveAddress.call{
                    value: bnbReceived
                }("");

            require(
                success,
                "Hive funding failed"
            );

            emit HiveFunded(
                tokenAmount,
                bnbReceived
            );
        }

        swapping = false;
    }
}
