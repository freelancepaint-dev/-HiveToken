
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken V5 - TESTNET CANDIDATE

    Supply: 1,000,000 HIVE
    Buy tax: 2.5%
    Sell tax: 2.5%
    Wallet transfer tax: 0%

    Automatic funding threshold: 100 HIVE

    Improvements over V4:
    - Failed funding attempts do not automatically
      revert the customer's sell.
    - Funding success and failure are recorded.
    - Swaps use a minimum output based on a
      router quote and a slippage setting.
    - Pair configuration is permanent.

    IMPORTANT:
    This contract is not audited.
    Router quotes are NOT independent price oracles.
    Do not deploy to mainnet without further review.
*/

interface IV5HiveReceiver {
    function buyEggs(address ref) external payable;
}

interface IV5Router {
    function WETH() external pure returns (address);

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

contract HiveTokenV5 {

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

    uint256 public constant swapThreshold =
        100 * 10**18;

    // Maximum permitted slippage: 5%.
    // This is relative to the router's spot quote.
    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    // Limit the gas consumed by a failed funding
    // attempt so ordinary sells can continue.
    uint256 public constant FUNDING_GAS_LIMIT = 650_000;

    address public immutable owner;
    address payable public immutable hiveAddress;
    IV5Router public immutable router;

    address public pair;
    bool public pairLocked;

    bool private swapping;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256))
        public allowance;

    mapping(address => bool) public isTaxExempt;

    uint256 public successfulFundingCount;
    uint256 public failedFundingCount;
    uint256 public totalHiveFunded;
    uint256 public totalBnbFunded;

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    event Approval(
        address indexed tokenOwner,
        address indexed spender,
        uint256 amount
    );

    event PairConfigured(address indexed pairAddress);

    event TaxCollected(
        address indexed from,
        uint256 amount
    );

    event HiveFunded(
        uint256 hiveAmount,
        uint256 bnbAmount
    );

    event FundingFailed(bytes reason);

    event FundingSkippedLowGas(uint256 gasAvailable);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlySelf() {
        require(
            msg.sender == address(this),
            "Internal call only"
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
            "Zero receiver"
        );

        require(
            routerAddress.code.length > 0,
            "Router not contract"
        );

        require(
            hiveFundingAddress.code.length > 0,
            "Receiver not contract"
        );

        owner = msg.sender;

        router = IV5Router(routerAddress);

        hiveAddress = hiveFundingAddress;

        isTaxExempt[msg.sender] = true;
        isTaxExempt[address(this)] = true;

        balanceOf[msg.sender] = totalSupply;

        emit Transfer(
            address(0),
            msg.sender,
            totalSupply
        );
    }

    receive() external payable {}

    function setPair(
        address pairAddress
    ) external onlyOwner {

        require(!pairLocked, "Pair already locked");

        require(
            pairAddress != address(0),
            "Zero pair"
        );

        require(
            pairAddress.code.length > 0,
            "Pair not contract"
        );

        require(
            pairAddress != address(this),
            "Invalid pair"
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
            from != address(0),
            "Zero sender"
        );

        require(
            to != address(0),
            "Zero receiver"
        );

        require(
            balanceOf[from] >= amount,
            "Insufficient balance"
        );

        /*
            Funding is triggered on a sell only
            after at least 100 HIVE has accumulated.

            Failure is isolated in an external
            self-call and caught below.
        */

        if (
            pairLocked &&
            to == pair &&
            !swapping &&
            balanceOf[address(this)] >= swapThreshold
        ) {

            if (
                gasleft() >
                FUNDING_GAS_LIMIT + 100_000
            ) {

                try this.executeFunding{
                    gas: FUNDING_GAS_LIMIT
                }() {
                    // Success recorded inside.
                } catch (bytes memory reason) {

                    failedFundingCount += 1;

                    emit FundingFailed(reason);
                }

            } else {

                emit FundingSkippedLowGas(gasleft());
            }
        }

        uint256 taxAmount = 0;

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

        uint256 sendAmount =
            amount - taxAmount;

        balanceOf[from] -= amount;

        balanceOf[to] += sendAmount;

        emit Transfer(
            from,
            to,
            sendAmount
        );

        if (taxAmount > 0) {

            balanceOf[address(this)] += taxAmount;

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

    /*
        External self-call permits try/catch
        isolation of funding failures.

        Ordinary users cannot call this directly.
    */

    function executeFunding()
        external
        onlySelf
    {

        require(!swapping, "Already swapping");

        uint256 tokenAmount =
            balanceOf[address(this)];

        require(
            tokenAmount >= swapThreshold,
            "Below threshold"
        );

        swapping = true;

        address[] memory path =
            new address[](2);

        path[0] = address(this);
        path[1] = router.WETH();

        /*
            IMPORTANT:
            This quote comes from the AMM itself.
            It is NOT manipulation-resistant.
        */

        uint256[] memory amounts =
            router.getAmountsOut(
                tokenAmount,
                path
            );

        require(
            amounts.length == 2,
            "Invalid quote"
        );

        uint256 expectedBnb = amounts[1];

        require(
            expectedBnb > 0,
            "Zero expected BNB"
        );

        uint256 minimumBnb =
            expectedBnb *
            (TAX_DENOMINATOR - MAX_SLIPPAGE_BPS) /
            TAX_DENOMINATOR;

        require(
            minimumBnb > 0,
            "Zero minimum output"
        );

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
            "Insufficient BNB received"
        );

        /*
            Call the existing BnBeeHive interface.
            No modification to BnBeeHive.
        */

        IV5HiveReceiver(hiveAddress)
            .buyEggs{
                value: bnbReceived
            }(
                address(0)
            );

        successfulFundingCount += 1;

        totalHiveFunded += tokenAmount;
        totalBnbFunded += bnbReceived;

        emit HiveFunded(
            tokenAmount,
            bnbReceived
        );

        swapping = false;
    }
}
