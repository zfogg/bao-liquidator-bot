// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "forge-std/console2.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/tokens/WETH.sol";
import { FlashLoanReceiverBase, ILendingPoolAddressesProvider } from "./interfaces/AaveV2Interfaces.sol";
import { bdToken, Stabilizer } from "./interfaces/BaoInterfaces.sol";
import { ISwapRouter } from "./interfaces/UniswapInterfaces.sol";
import { ICurve } from "./interfaces/CurveInterfaces.sol";
import { IVault } from "balancer-v2-monorepo/pkg/interfaces/contracts/vault/IVault.sol";
import { IAsset } from "balancer-v2-monorepo/pkg/interfaces/contracts/vault/IAsset.sol";

contract LiquidationController_baoETH is FlashLoanReceiverBase {
    ERC20 constant baoETH = ERC20(0x7945b0A6674b175695e5d1D08aE1e6F13744Abb0);
    bdToken constant bdbaoETH = bdToken(0xe853E5c1eDF8C51E81bAe81D742dd861dF596DE7);

    ERC20 constant bSTBL = ERC20(0x5ee08f40b637417bcC9d2C51B62F4820ec9cF5D8); // the bSTBL basket
    ERC20 constant bdbSTBL = ERC20(0xb0f8Fe96b4880adBdEDE0dDF446bd1e7EF122C4e);

    ERC20 constant bETH = ERC20(0xa1e3F062CE5825c1e19207cd93CEFdaD82A8A631); // the bETH basket
    ERC20 constant bdbETH = ERC20(0xf7548a6e9DAf2e4689CEDD8A08189d0D6f3Ee91b);

    ERC20 constant bdEther = ERC20(0x104079a87CE46fe2Cf27b811f6b406b69F6872B3); // Ether wrapped in a cToken especially for Ether

    WETH constant wrappedETH = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 constant DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    ERC20 constant USDC = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    IVault constant balancerVault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8); // v2 Balancer Vault
    bytes32 constant balancerPoolId_baoETH_weth = 0x1a44e35d5451e0b78621a1b3e7a53dfaa306b1d000000000000000000000051b;
    bytes32 constant balancerPoolId_bETH_weth = 0x00;
    bytes32 constant balancerPoolId_dai_weth = 0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a;

    ICurve constant curvePoolbSTBL = ICurve(0xA148BD19E26Ff9604f6A608E22BFb7B772D0d1A3); // bSTBL-DAI
    ISwapRouter constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // UniV3 Router

    address immutable public owner; // Only used for the retrieve function, no need to use OZ's Ownable or Solmate's Auth

    event log_named_uint(string key, uint val);

    mapping(address => uint24) poolFee;

    constructor(
        address _lpap
    ) FlashLoanReceiverBase(ILendingPoolAddressesProvider(_lpap)) {
        owner = msg.sender;

        // Approve tokens on contract creation to save gas during liquidations
        DAI.approve(address(balancerVault), type(uint256).max);
        baoETH.approve(address(balancerVault), type(uint256).max);
        baoETH.approve(address(bdbaoETH), type(uint256).max);
        wrappedETH.approve(address(swapRouter), type(uint256).max);
        wrappedETH.approve(address(balancerVault), type(uint256).max);
        bSTBL.approve(address(curvePoolbSTBL), type(uint256).max);
        bETH.approve(address(balancerVault), type(uint256).max);
        USDC.approve(address(swapRouter), type(uint256).max);
    }

    // This function is called after the contract has received the flash loan
    function executeOperation(
        address[] calldata,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata _params
    ) external override returns(bool) {
        (address _borrower, uint256 _repayAmount, address _bdCollateral) = abi.decode(_params, (address, uint256, address));

        // swap DAI to baoETH
        // 1. swap DAI to wETH
        _balancerSwap(amounts[0], address(DAI), address(wrappedETH), payable(address(this)), balancerPoolId_dai_weth);
        // 2. swap wETH to baoETH
        //_balancerSwap(wrappedETH.balanceOf(address(this)), address(wrappedETH), address(baoETH), payable(address(this)), balancerPoolId_baoETH_weth);

        // If liquidation doesn't succed, we revert
        //require(bdbaoETH.liquidateBorrow(_borrower, _repayAmount, _bdCollateral) == 0);
        bdbaoETH.liquidateBorrow(_borrower, _repayAmount, _bdCollateral);

        bdToken bdCollateral = bdToken(_bdCollateral);

        bdCollateral.redeem(bdCollateral.balanceOf(address(this)));
        ISwapRouter.ExactInputSingleParams memory params;
        uint collateralAmount;

        console2.log("about to look at collateral type");

        // If we are handling eth -> transform to weth before selling
        if (_bdCollateral==address(bdEther)) {
            console2.log("Collateral type: Ether");
            collateralAmount = address(this).balance;

            // ETH to WETH
            wrappedETH.deposit{value: collateralAmount}();

            // Define Swap Params
            params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(wrappedETH),
                tokenOut: address(DAI),
                fee: 3000, // Hardcoded cause SLOADs are expensive (361 gas here)
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: collateralAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            // Execute Swap
            swapRouter.exactInputSingle(params);
        }
        else if (_bdCollateral==address(bdbSTBL)) {
            console2.log("Collateral type: bSTBL");
            // Get amount of seized assets
            address underlyingCollateral = bdCollateral.underlying();
            collateralAmount = ERC20(underlyingCollateral).balanceOf(address(this));
            //Swap bSTBL for DAI on Curve
            bSTBL.approve(address(curvePoolbSTBL), collateralAmount);
            curvePoolbSTBL.exchange(1, 0, collateralAmount, 0);
        }
        else if (_bdCollateral==address(bdbETH)) {
            console2.log("Collateral type: bETH");
            address underlyingCollateral = bdCollateral.underlying();
            collateralAmount = ERC20(underlyingCollateral).balanceOf(address(this));
            //bETH.approve(address(balancerVault), collateralAmount);
            //_balancerSwap(collateralAmount, address(bETH), address(DAI), payable(address(this)), balancerPoolId_bETH_weth);
        }
        // Swapping USDC for DAI
        else {
            console2.log("Collateral type: unknown! Trusting Uniswap...");
            // Get amount of seized assets
            address underlyingCollateral = bdCollateral.underlying();
            collateralAmount = ERC20(underlyingCollateral).balanceOf(address(this));

            // Define Swap Params
            params = ISwapRouter.ExactInputSingleParams({
                tokenIn: underlyingCollateral,
                tokenOut: address(DAI),
                fee: 100, //0.01%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: collateralAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

            // Execute Swap
            swapRouter.exactInputSingle(params);
        }
        uint totalDebt = amounts[0] + premiums[0];
        DAI.approve(address(LENDING_POOL), totalDebt);
        return true;
    }

    /**
      * @notice Method to liquidate users given an address, amount and asset.
      * @param _borrower The addresses whose borrow we are going to repay (liquidations)
      * @param _repayAmount The number of borrowed assets we want to repay
      * @param _bdCollateral The bdToken address of the collateral we want to claim
      */
    function executeLiquidations(
        address _borrower,
        uint256 _repayAmount,
        address _bdCollateral,
        uint256 _loan_amount,
        address _receiver
    ) external {
        bytes memory params = abi.encode(_borrower, _repayAmount, _bdCollateral);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _loan_amount;

        address[] memory assets = new address[](1);
        assets[0] = address(DAI);

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        LENDING_POOL.flashLoan(address(this), assets, amounts, modes, address(this), params, 0);

        // Transfer funds to _receiver (to avoid griefing attack)
        DAI.transfer(_receiver, DAI.balanceOf(address(this)));
    }

    // In case any funds are sent to the contract, allow the owner to retrieve them
    function retrieve(address token, uint256 amount) external {
        require(owner == msg.sender, "Must be owner");

        ERC20 tokenContract = ERC20(token);
        tokenContract.transfer(msg.sender, amount);
    }

    /// @dev Perform a swap via Balancer
    /// @param _amount Amount of ETH to swap
    /// @param _from The token input
    /// @param _to The token output
    /// @param _recipient The recipient of the output tokens
    function _balancerSwap(uint256 _amount, address _from, address _to, address payable _recipient, bytes32 _poolId) private {
        if (_amount == 0) {
            return;
        }

        IVault.SingleSwap memory swap;
        swap.poolId = _poolId;
        swap.kind = IVault.SwapKind.GIVEN_IN;
        swap.assetIn = IAsset(_from);
        swap.assetOut = IAsset(_to);
        swap.amount = _amount;

        IVault.FundManagement memory fundManagement;
        fundManagement.sender = address(this);
        fundManagement.recipient = _recipient;
        fundManagement.fromInternalBalance = false;
        fundManagement.toInternalBalance = false;
        // Approve the vault to spend our WETH TransferHelper.safeApprove(_from, address(balancerVault), _amount);
        // Execute swap
        balancerVault.swap(swap, fundManagement, 0, block.timestamp);
    }

    // Needed for bdEther redeem
    receive() external payable {}
}
