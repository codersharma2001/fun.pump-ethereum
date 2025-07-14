// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "./Token.sol";
import "uniswap-v2-core/interfaces/IUniswapV2Factory.sol";
import "uniswap-v2-periphery/interfaces/IUniswapV2Router02.sol";
import "uniswap-v2-core/interfaces/IUniswapV2Pair.sol";

contract TokenFactory {
    enum TokenState {
        NOT_EXIST, // Token hasn't been created or registered yet
        ICO, // Token is in the initial coin offering phase (buyable but not withdrawable)
        TRADING // Token has launched; liquidity is live and users can withdraw their purchased tokens
    }

    uint256 public constant DECIMALS = 10 ** 18; // Standard ERC20 token decimal precision (18)
    uint256 public constant MAX_SUPPLY = (10 ** 9) * DECIMALS; // Max total token supply = 1 billion tokens
    uint256 public constant INITIAL_MINT = MAX_SUPPLY * 20 / 100; // 20% of max supply minted at token creation
    uint256 public constant k = 46875; // Slope of the bonding curve (affects price increase per token)
    uint256 public constant offset = 18750000000000; // Base offset for bonding curve (starting price floor)
    uint256 public constant SCALING_FACTOR = 10 ** 21; // Scaling factor to normalize bonding curve output
    uint256 public constant FUNDING_GOAL = 30 ether; // Minimum ETH required to launch liquidity pool

    address public constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Uniswap V2 factory address (mainnet)
    address public constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // Uniswap V2 router address (mainnet)

    mapping(address => TokenState) public tokens; // Tracks lifecycle state (ICO/TRADING) of each token
    mapping(address => uint256) public collateral; // Total ETH raised per token during ICO
    mapping(address => mapping(address => uint256)) public balances; // User token balances during ICO (before withdrawal)



    /// @notice Deploys a new ERC20 token and registers it for an ICO.
    /// @param name The name of the token (e.g., "MyToken").
    /// @param ticker The symbol of the token (e.g., "MTK").
    /// @return The address of the newly deployed token contract.
    ///
    /// Function logic:
    /// - Instantiates a new `Token` contract with the given name and ticker.
    /// - Automatically mints `INITIAL_MINT` tokens to the deployer inside the Token constructor.
    /// - Registers the token’s address in the `tokens` mapping and sets its state to `ICO`.
    /// - Returns the token address so the creator can reference or display it.
    ///
    /// ⚠️ Once created, users can start participating in the ICO using `buy()`.

    function createToken(string memory name, string memory ticker) external returns (address) {
        Token token = new Token(name, ticker, INITIAL_MINT);
        tokens[address(token)] = TokenState.ICO;
        return address(token);
    }

    /// @notice Allows users to buy tokens during the ICO phase by sending ETH.
    /// @param _tokenAddress The address of the token being purchased.
    /// @param amount The number of tokens the user wants to buy (in smallest unit).
    ///
    /// Function logic:
    /// - Ensures the token is currently in the ICO phase.
    /// - Checks that the requested amount doesn’t exceed remaining supply (MAX_SUPPLY - INITIAL_MINT - current total supply).
    /// - Calculates the required ETH using the bonding curve pricing model.
    /// - Validates that the user sent enough ETH (`msg.value >= requiredETH`).
    /// - Records ETH as collateral for the token, and logs the user’s balance (to be withdrawn later).
    /// - Mints the purchased tokens to this contract (held until claimable post-ICO).
    ///
    /// Funding goal check:
    /// - If total ETH raised (collateral) ≥ FUNDING_GOAL:
    ///   - Creates a Uniswap liquidity pool (token/WETH).
    ///   - Seeds it with INITIAL_MINT tokens + all collected ETH.
    ///   - Burns LP tokens to lock liquidity permanently.
    ///   - Transitions token state to TRADING, allowing users to claim their tokens.
    ///
    /// ⚠️ User must later call `withdraw()` to claim their tokens after TRADING begins.

    function buy(address _tokenAddress, uint256 amount) external payable {
        require(tokens[_tokenAddress] == TokenState.ICO, "Token doesn't exist or available for ICO");

        Token token = Token(_tokenAddress);
        uint256 availableSupply = MAX_SUPPLY - INITIAL_MINT - token.totalSupply();
        require(amount <= availableSupply, "Not enough available supply");

        uint256 requiredETH = calculateRequiredEth(_tokenAddress, amount);
        require(msg.value >= requiredETH, "Not enough ETH");

        collateral[_tokenAddress] += requiredETH;
        balances[_tokenAddress][msg.sender] += amount;
        token.mint(address(this), amount);

        if (collateral[_tokenAddress] >= FUNDING_GOAL) {
            address pool = _createLiquidityPool(_tokenAddress);
            uint256 liquidity = _provideLiquidity(_tokenAddress, INITIAL_MINT, collateral[_tokenAddress]);
            _burnLpTokens(pool, liquidity);
            tokens[_tokenAddress] = TokenState.TRADING;
        }
    }

    /// @notice Calculates the amount of ETH required to purchase a given number of tokens based on a linear bonding curve.
    /// @param tokenAddress The address of the token being purchased.
    /// @param amount The number of tokens the user wants to buy (in smallest unit).
    /// @return The amount of ETH required to mint the specified `amount` of tokens.
    ///
    /// How it works:
    /// - Uses the bonding curve formula: f(x) = k * x + offset
    /// - Calculates area under the curve (integral) from current supply `a` to new supply `b`
    /// - Applies trapezoidal rule: ∫f(x)dx ≈ (b - a) * (f(a) + f(b)) / 2
    /// - Divides by SCALING_FACTOR to normalize the result
    ///
    /// ⚠️ Assumes token.totalSupply() includes only post-ICO minting, so INITIAL_MINT is subtracted from both ends.


    function calculateRequiredEth(address tokenAddress, uint256 amount) public view returns (uint256) {
        Token token = Token(tokenAddress);
        uint256 b = token.totalSupply() + amount - INITIAL_MINT;
        uint256 a = token.totalSupply() - INITIAL_MINT;
        uint256 f_a = k * a + offset;
        uint256 f_b = k * b + offset;
        return ((b - a) * (f_a + f_b)) / (2 * SCALING_FACTOR);
    }

    /// @notice Allows users to claim their purchased tokens after the ICO has ended and trading has started.
    /// @param tokenAddress The address of the token being withdrawn.
    ///
    /// This function performs the following steps:
    /// - Ensures the token is in the TRADING phase, meaning liquidity has been seeded and withdrawals are enabled.
    /// - Fetches the user's token balance recorded during the ICO phase.
    /// - Reverts if the user has nothing to withdraw.
    /// - Sets the user’s balance to zero first (to prevent re-entrancy).
    /// - Transfers the corresponding token amount from the contract to the user’s wallet.
    ///
    /// ⚠️ Users must call this manually to receive their tokens after launch — no auto-distribution.

    function withdraw(address tokenAddress) external {
        require(tokens[tokenAddress] == TokenState.TRADING, "Token not in trading phase");
        uint256 balance = balances[tokenAddress][msg.sender];
        require(balance > 0, "No tokens to withdraw");
        balances[tokenAddress][msg.sender] = 0;

        Token token = Token(tokenAddress);
        token.transfer(msg.sender, balance);
    }

    /// @dev Internal helper to create a new Uniswap V2 liquidity pool for the given token.
    /// @param tokenAddress The address of the ERC-20 token to pair with WETH.
    /// @return pair The address of the newly created Uniswap pair (token/WETH).
    /// 
    /// This function does the following:
    /// - Initializes interfaces for the Uniswap V2 factory and router.
    /// - Calls `createPair()` on the factory to deploy a new pair contract between the token and WETH.
    /// - Returns the address of the newly created pair so it can be used later for liquidity provisioning.
    ///
    /// ⚠️ Assumes the token doesn’t already have a pair — if a pair exists, Uniswap will revert.


    function _createLiquidityPool(address tokenAddress) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(UNISWAP_V2_FACTORY);
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        address pair = factory.createPair(tokenAddress, router.WETH());
        return pair;
    }

    /// @dev Internally adds liquidity to Uniswap by pairing the token with ETH.
    /// @param tokenAddress The address of the token being listed.
    /// @param tokenAmount The amount of tokens to provide as liquidity.
    /// @param ethAmount The amount of ETH to pair with the tokens.
    /// @return liquidity The amount of LP (liquidity provider) tokens minted by Uniswap.
    ///
    /// Function steps:
    /// - Instantiates the token and Uniswap router contracts.
    /// - Approves the Uniswap router to spend the specified `tokenAmount`.
    /// - Calls `addLiquidityETH()` on the router, pairing the token with ETH.
    ///   - Sets `minAmount` of both assets equal to desired amounts (no slippage protection).
    ///   - Sends LP tokens to this contract.
    /// - Returns the number of LP tokens minted.
    ///
    /// ⚠️ Assumes this contract holds at least `tokenAmount` tokens and `ethAmount` ETH before calling.
    /// ⚠️ LP tokens must be burned later to lock liquidity (see `_burnLpTokens`).

    function _provideLiquidity(address tokenAddress, uint256 tokenAmount, uint256 ethAmount)
        internal
        returns (uint256)
    {
        Token token = Token(tokenAddress);
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);

        token.approve(UNISWAP_V2_ROUTER, tokenAmount);

        (,, uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
            tokenAddress, tokenAmount, tokenAmount, ethAmount, address(this), block.timestamp
        );

        return liquidity;
    }

    /// @dev Burns LP tokens by sending them to the zero address (permanently removing them).
    /// @param poolAddress The address of the Uniswap V2 pair (token/WETH).
    /// @param amount The number of LP tokens to burn.
    ///
    /// Function steps:
    /// - Instantiates the Uniswap pair contract using the provided pool address.
    /// - Transfers `amount` of LP tokens from this contract to the zero address (`address(0)`).
    ///
    /// 🔥 This effectively locks liquidity forever by making the LP tokens unrecoverable.
    /// ⚠️ Assumes this contract holds at least `amount` of LP tokens before calling.

    function _burnLpTokens(address poolAddress, uint256 amount) internal {
        IUniswapV2Pair pool = IUniswapV2Pair(poolAddress);
        pool.transfer(address(0), amount);
    }
}
