// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {Token} from "../src/Token.sol";

contract TokenFactoryTest is Test {
    TokenFactory public factory;
    address public user;

    function setUp() public {
        factory = new TokenFactory();
        user = address(0xBEEF);
        vm.deal(user, 1000 ether);
    }

    function test_CreateToken() public {
        address tokenAddr = factory.createToken("MyToken", "MYT");
        Token token = Token(tokenAddr);

        assertEq(token.totalSupply(), factory.INITIAL_MINT());
        assertEq(token.balanceOf(address(factory)), factory.INITIAL_MINT());
        assertEq(uint256(factory.tokens(tokenAddr)), uint256(TokenFactory.TokenState.ICO));
    }

    function test_CalculateEthRequirementMonotonic() public {
        address tokenAddr = factory.createToken("MyToken", "MYT");

        uint256 eth1 = factory.calculateRequiredEth(tokenAddr, 1 ether);
        uint256 eth2 = factory.calculateRequiredEth(tokenAddr, 2 ether);
        uint256 eth4 = factory.calculateRequiredEth(tokenAddr, 4 ether);

        assertGt(eth2, eth1);
        assertGt(eth4, eth2);
    }

    function test_BuyFailsOnInsufficientETH() public {
        address tokenAddr = factory.createToken("FailToken", "FL");
        vm.prank(user);
        vm.expectRevert("Not enough ETH");
        factory.buy{value: 1 wei}(tokenAddr, 1 ether);
    }

    function test_BuyTokenSuccess() public {
        address tokenAddr = factory.createToken("TestBuy", "TBY");
        Token token = Token(tokenAddr);
        uint256 amount = 1 ether;
        uint256 requiredETH = factory.calculateRequiredEth(tokenAddr, amount);

        vm.prank(user);
        factory.buy{value: requiredETH}(tokenAddr, amount);

        assertEq(factory.balances(tokenAddr, user), amount);
        assertEq(factory.collateral(tokenAddr), requiredETH);
        assertEq(token.balanceOf(address(factory)), factory.INITIAL_MINT() + amount);
    }

    function test_WithdrawFailsBeforeTrading() public {
        address tokenAddr = factory.createToken("WithdrawFail", "WDF");
        vm.prank(user);
        vm.expectRevert("Token not in trading phase");
        factory.withdraw(tokenAddr);
    }

    function test_WithdrawFailsIfNoBalance() public {
        address tokenAddr = factory.createToken("WithdrawZero", "WDZ");

        // Force trading state manually
        bytes32 tokenSlot = keccak256(abi.encode(tokenAddr, uint256(0)));
        vm.store(address(factory), tokenSlot, bytes32(uint256(TokenFactory.TokenState.TRADING)));

        vm.prank(user);
        vm.expectRevert("No tokens to withdraw");
        factory.withdraw(tokenAddr);
    }

    function test_FullFlowTriggerLiquidityAndWithdraw() public {
        address tokenAddr = factory.createToken("PumpIt", "PI");
        Token token = Token(tokenAddr);

        uint256 buyAmount = 1 ether; // Keep it small to avoid hitting FUNDING_GOAL
        uint256 requiredETH = factory.calculateRequiredEth(tokenAddr, buyAmount);

        vm.prank(user);
        factory.buy{value: requiredETH}(tokenAddr, buyAmount);

        // ✅ Manually set token state to TRADING (tokens → slot 0)
        bytes32 tokenSlot = keccak256(abi.encode(tokenAddr, uint256(0)));
        vm.store(address(factory), tokenSlot, bytes32(uint256(TokenFactory.TokenState.TRADING)));

        assertEq(factory.balances(tokenAddr, user), buyAmount);

        vm.prank(user);
        factory.withdraw(tokenAddr);

        assertEq(token.balanceOf(user), buyAmount);
        assertEq(factory.balances(tokenAddr, user), 0);
    }
}
