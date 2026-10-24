
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * HiveToken V7
 * TESTNET ONLY - NOT AUDITED
 *
 * Fixed supply: 1,000,000 HIVE
 * Buy tax: 2.5%
 * Sell tax: 2.5%
 * Wallet transfers: 0%
 *
 * Funding threshold: 100 HIVE
 * Funding batch: 100 HIVE
 *
 * Funding is separate from buy/sell transactions.
 */

interface IHiveFundingReceiverV7 {
    function buyEggs(address ref) external payable;
}

interface IHiveRouterV7 {
    function WETH() external pure returns (address);
    function factory() external pure returns (address);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IHiveFactoryV7 {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address);
}

interface IHivePairV7 {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract HiveTokenV7 {

    string public constant name = "Hive Token";
    string public constant symbol = "HIVE";
    uint8 public constant decimals = 18;

    uint256 public constant totalSupply = 1_000_000 * 1e18;

    uint256 public constant OWNER_ALLOCATION = 150_000 * 1e18;
    uint256 public constant LIQUIDITY_ALLOCATION = 850_000 * 1e18;

    uint256 public constant BUY_TAX = 250;
    uint256 public constant SELL_TAX = 250;
    uint256 public constant TAX_DENOMINATOR = 10_000;

    uint256 public constant swapThreshold = 100 * 1e18;
    uint256 public constant MAX_SWAP_AMOUNT = 100 * 1e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    address public immutable owner;
    address payable public immutable hiveAddress;

    IHiveRouterV7 public immutable router;

    address public immutable wrappedBNB;
    address public immutable routerFactory;

    address public pair;
    bool public pairLocked;
    bool private swapping;

    uint256 public minimumFundingBnb;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256))
        public allowance;

    mapping(address => bool) public isTaxExempt;

    uint256 public successfulFundingCount;
    uint256 public failedFundingCount;
    uint256 public skippedFundingCount;

    uint256 public totalHiveFunded;
    uint256 public totalBnbFunded;

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed tokenOwner,
        address indexed spender,
        uint256 value
    );

    event PairConfigured(address indexed pairAddress);
    event MinimumFundingBnbConfigured(uint256 amount);

    event TaxCollected(
        address indexed from,
        uint256 amount
    );

    event FundingReady(uint256 balance);

    event HiveFunded(
        uint256 hiveAmount,
        uint256 bnbAmount
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrantFunding() {
        require(!swapping, "Funding in progress");
        swapping = true;
        _;
        swapping = false;
    }

    constructor(
        address routerAddress,
        address payable hiveFundingAddress
    ) {
        require(
            routerAddress.code.length > 0,
            "Router not contract"
        );

        require(
            hiveFundingAddress.code.length > 0,
            "Receiver not contract"
        );

        owner = msg.sender;
        router = IHiveRouterV7(routerAddress);
        hiveAddress = hiveFundingAddress;

        wrappedBNB = IHiveRouterV7(routerAddress).WETH();
        routerFactory = IHiveRouterV7(routerAddress).factory();

        require(
            wrappedBNB != address(0),
            "Zero wrapped BNB"
        );

        require(
            routerFactory.code.length > 0,
            "Factory not contract"
        );

        isTaxExempt[msg.sender] = true;
        isTaxExempt[address(this)] = true;

        balanceOf[msg.sender] = totalSupply;

        emit Transfer(
            address(0),
            msg.sender,
            totalSupply
        );
    }

    receive() external payable {
        require(
            msg.sender == wrappedBNB ||
            msg.sender == address(router),
            "Unexpected BNB"
        );
    }

    function setMinimumFundingBnb(
        uint256 amount
    ) external onlyOwner {

        require(!pairLocked, "Pair already locked");
        require(amount > 0, "Minimum must be positive");

        minimumFundingBnb = amount;

        emit MinimumFundingBnbConfigured(amount);
    }

    function setPair(
        address pairAddress
    ) external onlyOwner {

        require(!pairLocked, "Pair already locked");

        require(
            minimumFundingBnb > 0,
            "Configure BNB minimum first"
        );

        require(
            pairAddress.code.length > 0,
            "Pair not contract"
        );

        require(
            pairAddress ==
                IHiveFactoryV7(routerFactory).getPair(
                    address(this),
                    wrappedBNB
                ),
            "Incorrect factory pair"
        );

        address a = IHivePairV7(pairAddress).token0();
        address b = IHivePairV7(pairAddress).token1();

        require(
            (
                a == address(this) &&
                b == wrappedBNB
            ) ||
            (
                b == address(this) &&
                a == wrappedBNB
            ),
            "Incorrect pair tokens"
        );

        pair = pairAddress;
        pairLocked = true;

        emit PairConfigured(pairAddress);
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

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] =
                allowed - amount;

            emit Approval(
                from,
                msg.sender,
                allowance[from][msg.sender]
            );
        }

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {

        require(
            from != address(0) &&
            to != address(0),
            "Zero address"
        );

        if (swapping) {
            require(
                msg.sender == address(router) &&
                from == address(this) &&
                to == pair,
                "Transfer blocked during funding"
            );
        }

        require(
            balanceOf[from] >= amount,
            "Insufficient balance"
        );

        uint256 taxAmount;

        if (
            pairLocked &&
            !swapping &&
            !isTaxExempt[from] &&
            !isTaxExempt[to]
        ) {
            if (from == pair) {
                taxAmount =
                    amount * BUY_TAX /
                    TAX_DENOMINATOR;
            } else if (to == pair) {
                taxAmount =
                    amount * SELL_TAX /
                    TAX_DENOMINATOR;
            }
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount - taxAmount;

        emit Transfer(
            from,
            to,
            amount - taxAmount
        );

        if (taxAmount > 0) {

            uint256 previous =
                balanceOf[address(this)];

            balanceOf[address(this)] =
                previous + taxAmount;

            emit Transfer(
                from,
                address(this),
                taxAmount
            );

            emit TaxCollected(from, taxAmount);

            if (
                previous < swapThreshold &&
                balanceOf[address(this)] >= swapThreshold
            ) {
                emit FundingReady(
                    balanceOf[address(this)]
                );
            }
        }
    }

    function fundingReady()
        external
        view
        returns (bool)
    {
        return (
            pairLocked &&
            !swapping &&
            balanceOf[address(this)] >= swapThreshold
        );
    }

    /*
     * Called separately by a keeper or wallet.
     * Ordinary buys and sells never call this function.
     */

    function executeFunding()
        external
        nonReentrantFunding
    {
        require(
            pairLocked,
            "Pair not configured"
        );

        require(
            minimumFundingBnb > 0,
            "BNB minimum not configured"
        );

        uint256 availableTokens =
            balanceOf[address(this)];

        require(
            availableTokens >= swapThreshold,
            "Below threshold"
        );

        uint256 tokenAmount =
            availableTokens > MAX_SWAP_AMOUNT
                ? MAX_SWAP_AMOUNT
                : availableTokens;

        address[] memory path =
            new address[](2);

        path[0] = address(this);
        path[1] = wrappedBNB;

        uint256[] memory amounts =
            router.getAmountsOut(
                tokenAmount,
                path
            );

        require(
            amounts.length == 2 &&
            amounts[1] > 0,
            "Invalid router quote"
        );

        uint256 slippageMinimum =
            amounts[1] *
            (TAX_DENOMINATOR - MAX_SLIPPAGE_BPS) /
            TAX_DENOMINATOR;

        uint256 minimumBnb =
            minimumFundingBnb > slippageMinimum
                ? minimumFundingBnb
                : slippageMinimum;

        allowance[address(this)][address(router)] =
            tokenAmount;

        emit Approval(
            address(this),
            address(router),
            tokenAmount
        );

        uint256 bnbBefore =
            address(this).balance;

        router
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                minimumBnb,
                path,
                address(this),
                block.timestamp
            );

        uint256 bnbReceived =
            address(this).balance - bnbBefore;

        require(
            bnbReceived >= minimumBnb,
            "BNB received below minimum"
        );

        allowance[address(this)][address(router)] = 0;

        emit Approval(
            address(this),
            address(router),
            0
        );

        IHiveFundingReceiverV7(hiveAddress)
            .buyEggs{value: bnbReceived}(address(0));

        successfulFundingCount += 1;
        totalHiveFunded += tokenAmount;
        totalBnbFunded += bnbReceived;

        emit HiveFunded(
            tokenAmount,
            bnbReceived
        );
    }
}
