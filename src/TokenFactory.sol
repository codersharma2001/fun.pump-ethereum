// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "./Token.sol";
import "uniswap-v2-core/interfaces/IUniswapV2Factory.sol";
import "uniswap-v2-periphery/interfaces/IUniswapV2Router02.sol";
import "uniswap-v2-core/interfaces/IUniswapV2Pair.sol";

contract TokenFactory {
    enum TokenState {
        NOT_EXIST,
        ICO,
        TRADING
    }

    uint256 public constant DECIMALS = 10 ** 18;
    uint256 public constant MAX_SUPPLY = (10 ** 9) * DECIMALS;
    uint256 public constant INITIAL_MINT = MAX_SUPPLY * 20 / 100;
    uint256 public constant k = 46875;
    uint256 public constant offset = 18750000000000;
    uint256 public constant SCALING_FACTOR = 10 ** 21;
    uint256 public constant FUNDING_GOAL = 30 ether;

    address public constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address public constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    mapping(address => TokenState) public tokens;
    mapping(address => uint256) public collateral;
    mapping(address => mapping(address => uint256)) public balances;

    function createToken(string memory name, string memory ticker) external returns (address) {
        Token token = new Token(name, ticker, INITIAL_MINT);
        tokens[address(token)] = TokenState.ICO;
        return address(token);
    }

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

    function calculateRequiredEth(address tokenAddress, uint256 amount) public view returns (uint256) {
        Token token = Token(tokenAddress);
        uint256 b = token.totalSupply() + amount - INITIAL_MINT;
        uint256 a = token.totalSupply() - INITIAL_MINT;
        uint256 f_a = k * a + offset;
        uint256 f_b = k * b + offset;
        return ((b - a) * (f_a + f_b)) / (2 * SCALING_FACTOR);
    }

    function withdraw(address tokenAddress) external {
        require(tokens[tokenAddress] == TokenState.TRADING, "Token not in trading phase");
        uint256 balance = balances[tokenAddress][msg.sender];
        require(balance > 0, "No tokens to withdraw");
        balances[tokenAddress][msg.sender] = 0;

        Token token = Token(tokenAddress);
        token.transfer(msg.sender, balance);
    }

    function _createLiquidityPool(address tokenAddress) internal returns (address) {
        IUniswapV2Factory factory = IUniswapV2Factory(UNISWAP_V2_FACTORY);
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        address pair = factory.createPair(tokenAddress, router.WETH());
        return pair;
    }

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

    function _burnLpTokens(address poolAddress, uint256 amount) internal {
        IUniswapV2Pair pool = IUniswapV2Pair(poolAddress);
        pool.transfer(address(0), amount);
    }
}
