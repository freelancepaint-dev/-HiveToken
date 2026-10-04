// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    HiveToken - Tax Testnet V4

    Fixed Supply: 1,000,000 HIVE

    Buy Tax: 2.5%
    Sell Tax: 2.5%
    Wallet Transfers: 0%

    Tax Flow:

    HIVE tax
        ->
    HiveToken contract
        ->
    PancakeSwap HIVE -> BNB
        ->
    BnBeeHive.buyEggs(address(0))

    IMPORTANT:
    BnBeeHive is NOT modified.

    The BNB sent from HiveToken participates in the
    existing BnBeeHive buyEggs mechanics.

    Pair Setup:

    1. Deploy HiveToken
    2. Create/find HIVE/WBNB pair
    3. Owner calls setPair(pairAddress)
    4. Pair becomes permanently locked

    TESTNET FIRST.
*/


/* =========================================================
   BNBEEHIVE INTERFACE
   ========================================================= */

interface IBnBeeHive {

    function buyEggs(
        address ref
    ) external payable;

}


/* =========================================================
   PANCAKESWAP ROUTER INTERFACE
   ========================================================= */

interface IPancakeRouter {

    function WETH()
        external
        pure
        returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

}


/* =========================================================
   HIVETOKEN
   ========================================================= */

contract HiveToken {

    string public constant name =
        "Hive Token";

    string public constant symbol =
        "HIVE";

    uint8 public constant decimals =
        18;


    /* =====================================================
       SUPPLY
       ===================================================== */

    uint256 public constant totalSupply =
        1_000_000 * 10**18;

    uint256 public constant OWNER_ALLOCATION =
        150_000 * 10**18;

    uint256 public constant LIQUIDITY_ALLOCATION =
        850_000 * 10**18;


    /* =====================================================
       TAX
       ===================================================== */

    // 250 / 10,000 = 2.5%

    uint256 public constant BUY_TAX =
        250;

    uint256 public constant SELL_TAX =
        250;

    uint256 public constant TAX_DENOMINATOR =
        10_000;


    /* =====================================================
       ADDRESSES
       ===================================================== */

    address public immutable owner;

    address payable public immutable hiveAddress;

    IPancakeRouter public immutable router;


    /* =====================================================
       PAIR
       ===================================================== */

    address public pair;

    bool public pairLocked;


    /* =====================================================
       ERC20 STORAGE
       ===================================================== */

    mapping(address => uint256)
        public balanceOf;

    mapping(
        address =>
        mapping(address => uint256)
    )
        public allowance;


    /* =====================================================
       TAX EXEMPTION
       ===================================================== */

    mapping(address => bool)
        public isTaxExempt;


    /* =====================================================
       SWAP
       ===================================================== */

    bool private swapping;

    uint256 public constant swapThreshold =
        100 * 10**18;


    /* =====================================================
       EVENTS
       ===================================================== */

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


    /* =====================================================
       MODIFIERS
       ===================================================== */

    modifier onlyOwner() {

        require(
            msg.sender == owner,
            "Not owner"
        );

        _;
    }


    /* =====================================================
       CONSTRUCTOR
       ===================================================== */

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


        owner =
            msg.sender;


        router =
            IPancakeRouter(
                routerAddress
            );


        hiveAddress =
            hiveFundingAddress;


        /*
            Owner is exempt.

            This allows initial liquidity
            without charging the sell tax.
        */

        isTaxExempt[msg.sender] =
            true;


        /*
            HiveToken contract itself is exempt.

            This prevents the contract's automatic
            HIVE -> BNB swap from being taxed.
        */

        isTaxExempt[address(this)] =
            true;


        /*
            Mint fixed supply to deployer.
        */

        balanceOf[msg.sender] =
            totalSupply;


        emit Transfer(
            address(0),
            msg.sender,
            totalSupply
        );
    }


    /*
        Required because PancakeSwap sends native
        BNB back to HiveToken during the automatic
        tax swap.
    */

    receive()
        external
        payable
    {}


    /* =====================================================
       PAIR CONFIGURATION
       ===================================================== */

    /*
        Pair may be configured ONE TIME.

        After pairLocked becomes true,
        the pair can never be changed.
    */

    function setPair(
        address pairAddress
    )
        external
        onlyOwner
    {

        require(
            !pairLocked,
            "Pair already locked"
        );

        require(
            pairAddress != address(0),
            "Zero pair"
        );


        pair =
            pairAddress;


        pairLocked =
            true;


        emit PairConfigured(
            pairAddress
        );
    }


    /* =====================================================
       ERC20 TRANSFER
       ===================================================== */

    function transfer(
        address to,
        uint256 amount
    )
        external
        returns (bool)
    {

        _transfer(
            msg.sender,
            to,
            amount
        );

        return true;
    }


    /* =====================================================
       ERC20 APPROVE
       ===================================================== */

    function approve(
        address spender,
        uint256 amount
    )
        external
        returns (bool)
    {

        allowance[msg.sender][spender] =
            amount;


        emit Approval(
            msg.sender,
            spender,
            amount
        );


        return true;
    }


    /* =====================================================
       ERC20 TRANSFER FROM
       ===================================================== */

    function transferFrom(
        address from,
        address to,
        uint256 amount
    )
        external
        returns (bool)
    {

        uint256 allowed =
            allowance[from][msg.sender];


        require(
            allowed >= amount,
            "Allowance exceeded"
        );


        if (
            allowed !=
            type(uint256).max
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


    /* =====================================================
       INTERNAL TRANSFER
       ===================================================== */

    function _transfer(
        address from,
        address to,
        uint256 amount
    )
        internal
    {

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
            AUTOMATIC TAX SWAP

            The current transaction must be a SELL.

            The contract must already hold at least
            100 HIVE before this sell begins.

            The accumulated HIVE is swapped before
            processing the user's current sell.
        */

        if (
            pairLocked &&
            to == pair &&
            !swapping &&
            balanceOf[address(this)]
                >= swapThreshold
        ) {

            _swapTaxForBNB();
        }


        uint256 taxAmount =
            0;


        /*
            Tax only applies when:

            - pair is configured
            - contract is not internally swapping
            - sender is not exempt
            - receiver is not exempt
        */

        if (
            pairLocked &&
            !swapping &&
            !isTaxExempt[from] &&
            !isTaxExempt[to]
        ) {


            /*
                BUY

                Pair -> buyer
            */

            if (
                from == pair
            ) {

                taxAmount =
                    (
                        amount *
                        BUY_TAX
                    )
                    /
                    TAX_DENOMINATOR;
            }


            /*
                SELL

                Seller -> pair
            */

            else if (
                to == pair
            ) {

                taxAmount =
                    (
                        amount *
                        SELL_TAX
                    )
                    /
                    TAX_DENOMINATOR;
            }
        }


        uint256 sendAmount =
            amount -
            taxAmount;


        /*
            Remove complete amount
            from sender.
        */

        balanceOf[from] -=
            amount;


        /*
            Receiver receives amount
            after tax.
        */

        balanceOf[to] +=
            sendAmount;


        emit Transfer(
            from,
            to,
            sendAmount
        );


        /*
            Tax goes to HiveToken.
        */

        if (
            taxAmount > 0
        ) {

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


    /* =====================================================
       AUTOMATIC TAX -> BNB -> BNBEEHIVE
       ===================================================== */

    function _swapTaxForBNB()
        internal
    {

        uint256 tokenAmount =
            balanceOf[address(this)];


        if (
            tokenAmount == 0
        ) {

            return;
        }


        /*
            Prevent taxation / recursion while
            HiveToken performs its own swap.
        */

        swapping =
            true;


        /*
            Give PancakeSwap permission to spend
            the accumulated HIVE.
        */

        allowance[address(this)]
            [address(router)] =
            tokenAmount;


        emit Approval(
            address(this),
            address(router),
            tokenAmount
        );


        /*
            HIVE -> WBNB
        */

        address[] memory path =
            new address[](2);


        path[0] =
            address(this);


        path[1] =
            router.WETH();


        /*
            Record BNB balance before swap.
        */

        uint256 balanceBefore =
            address(this).balance;


        /*
            Swap accumulated HIVE tax
            into native BNB.

            amountOutMin = 0 is retained from
            the V3 implementation for testing.
        */

        router
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                0,
                path,
                address(this),
                block.timestamp
            );


        /*
            Determine exactly how much BNB
            PancakeSwap returned.
        */

        uint256 bnbReceived =
            address(this).balance -
            balanceBefore;


        /*
            V4 CHANGE

            Instead of attempting a plain BNB
            transfer to BnBeeHive, call its
            existing payable buyEggs function.

            Referral address = zero address.

            BnBeeHive remains completely unchanged.
        */

        if (
            bnbReceived > 0
        ) {

            IBnBeeHive(
                hiveAddress
            )
                .buyEggs{
                    value:
                        bnbReceived
                }(
                    address(0)
                );


            emit HiveFunded(
                tokenAmount,
                bnbReceived
            );
        }


        swapping =
            false;
    }
}
