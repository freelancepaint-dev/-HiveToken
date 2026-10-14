
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken V5 - REVISED TESTNET CANDIDATE

    Fixed supply: 1,000,000 HIVE
    Buy tax: 2.5%
    Sell tax: 2.5%
    Wallet-to-wallet tax: 0%

    Automatic funding threshold: 100 HIVE
    Maximum automatic funding batch: 100 HIVE

    Safety features:
    - Failed funding attempts are caught so the
      token's automatic funding logic does not
      automatically revert an ordinary sell.
    - Funding is attempted only when enough gas
      is available.
    - Each swap has a 5% maximum slippage limit
      relative to the router's current quote.
    - A separate minimum BNB output must be set
      before the trading pair is locked.
    - The pair must match the router's factory.
    - Token transfers during funding are restricted.
    - Funding outcomes are recorded on-chain.

    IMPORTANT:
    - NOT AUDITED.
    - AMM quotes are not independent price oracles.
    - Real BnBeeHive crediting requires an
      independent integration test.
    - LP tokens are NOT locked by this contract.
    - TESTNET FIRST. DO NOT DEPLOY TO MAINNET
      WITHOUT FURTHER REVIEW.
*/

interface IV5FundingReceiver {
    function buyEggs(address ref) external payable;
}

interface IV5Router {
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

interface IV5Factory {
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address);
}

interface IV5Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
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

    uint256 public constant MAX_SWAP_AMOUNT =
        100 * 10**18;

    uint256 public constant MAX_SLIPPAGE_BPS = 500;

    uint256 public constant FUNDING_GAS_LIMIT = 650_000;

    uint256 public constant SELL_GAS_RESERVE = 150_000;

    address public immutable owner;

    address payable public immutable hiveAddress;

    IV5Router public immutable router;

    address public immutable wrappedBNB;

    address public immutable routerFactory;

    address public pair;

    bool public pairLocked;

    bool private swapping;

    // Set this BEFORE locking the pair.
    // Units are wei of native BNB.
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

    event HiveFunded(
        uint256 hiveAmount,
        uint256 bnbAmount
    );

    event FundingFailed(bytes reason);

    event FundingSkippedLowGas(uint256 availableGas);

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

        address weth = IV5Router(routerAddress).WETH();

        address factoryAddress =
            IV5Router(routerAddress).factory();

        require(
            weth != address(0),
            "Zero wrapped BNB"
        );

        require(
            factoryAddress != address(0),
            "Zero factory"
        );

        require(
            factoryAddress.code.length > 0,
            "Factory not contract"
        );

        wrappedBNB = weth;
        routerFactory = factoryAddress;

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
            "Unexpected native BNB"
        );
    }

    /*
        Configure an absolute BNB floor before
        locking the trading pair.

        Example:
        0.0001 BNB = 100000000000000 wei

        This is only an example, NOT a universal
        safe setting. It must be selected using
        actual testnet liquidity and swap quotes.

        After pair locking, this value cannot
        be changed.
    */

    function setMinimumFundingBnb(
        uint256 amount
    ) external onlyOwner {

        require(!pairLocked, "Pair already locked");

        require(amount > 0, "Minimum must be positive");

        minimumFundingBnb = amount;

        emit MinimumFundingBnbConfigured(amount);
    }

    /*
        The pair must be the actual factory pair
        for HIVE and the router's wrapped BNB.
    */

    function setPair(
        address pairAddress
    ) external onlyOwner {

        require(!pairLocked, "Pair already locked");

        require(
            minimumFundingBnb > 0,
            "Configure BNB minimum first"
        );

        require(
            pairAddress != address(0),
            "Zero pair"
        );

        require(
            pairAddress.code.length > 0,
            "Pair not contract"
        );

        address expectedPair =
            IV5Factory(routerFactory).getPair(
                address(this),
                wrappedBNB
            );

        require(
            expectedPair != address(0),
            "Factory pair missing"
        );

        require(
            pairAddress == expectedPair,
            "Incorrect factory pair"
        );

        address tokenA =
            IV5Pair(pairAddress).token0();

        address tokenB =
            IV5Pair(pairAddress).token1();

        require(
            (
                tokenA == address(this) &&
                tokenB == wrappedBNB
            ) ||
            (
                tokenB == address(this) &&
                tokenA == wrappedBNB
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
            from != address(0),
            "Zero sender"
        );

        require(
            to != address(0),
            "Zero receiver"
        );

        /*
            While funding is in progress, only
            the router may move this contract's
            tokens directly into the configured
            liquidity pair.

            This blocks unexpected recursive
            token movements during external calls.
        */

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

        /*
            Attempt funding BEFORE processing
            the current sell.

            Only an already accumulated tax
            balance can trigger funding.
        */

        if (
            pairLocked &&
            to == pair &&
            !swapping &&
            balanceOf[address(this)] >= swapThreshold
        ) {

            _attemptFunding();
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
        Isolate the funding attempt in a separate
        external self-call.

        If the router or receiver reverts,
        the funding subcall is rolled back.

        The ordinary token transfer can then
        continue, provided sufficient gas remains.
    */

    function _attemptFunding() internal {

        uint256 available = gasleft();

        if (
            available <=
            FUNDING_GAS_LIMIT + SELL_GAS_RESERVE
        ) {

            skippedFundingCount += 1;

            emit FundingSkippedLowGas(available);

            return;
        }

        try this.executeFunding{
            gas: FUNDING_GAS_LIMIT
        }() {

            // Success counters are updated
            // inside executeFunding().

        } catch (bytes memory reason) {

            failedFundingCount += 1;

            emit FundingFailed(reason);
        }
    }

    /*
        Only the contract itself can call this.

        Each successful funding attempt swaps
        at most 100 HIVE.

        Any extra accumulated tax stays in
        the token contract for later attempts.
    */

    function executeFunding()
        external
        onlySelf
    {

        require(!swapping, "Already swapping");

        require(pairLocked, "Pair not configured");

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

        uint256 tokenAmount = availableTokens;

        if (tokenAmount > MAX_SWAP_AMOUNT) {

            tokenAmount = MAX_SWAP_AMOUNT;
        }

        swapping = true;

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
            amounts.length == 2,
            "Invalid router quote"
        );

        uint256 expectedBnb = amounts[1];

        require(
            expectedBnb > 0,
            "Zero expected BNB"
        );

        uint256 slippageMinimum =
            expectedBnb *
            (TAX_DENOMINATOR - MAX_SLIPPAGE_BPS) /
            TAX_DENOMINATOR;

        /*
            Use whichever minimum is higher:

            1. 95% of the router's current quote.
            2. The independently configured
               minimumFundingBnb floor.

            A manipulated router quote alone
            cannot reduce the output below
            the configured absolute floor.
        */

        uint256 minimumBnb = slippageMinimum;

        if (minimumFundingBnb > minimumBnb) {

            minimumBnb = minimumFundingBnb;
        }

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
            "BNB received below minimum"
        );

        /*
            Revoke any unused router allowance.
        */

        allowance[address(this)][address(router)] = 0;

        emit Approval(
            address(this),
            address(router),
            0
        );

        /*
            This confirms a payable call can
            be made, but does NOT independently
            prove the real BnBeeHive credits
            the intended beneficiary.

            That requires a separate test.
        */

        IV5FundingReceiver(hiveAddress)
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
