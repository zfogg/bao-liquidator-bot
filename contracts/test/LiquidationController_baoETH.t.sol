import "forge-std/Test.sol";
import "solmate/tokens/ERC20.sol";
import "../src/LiquidationController_baoETH.sol";
import {Constants} from "./Constants.sol";
import {ICToken} from "../src/interfaces/ICToken.sol";
import {IComptroller} from "../src/interfaces/IComptroller.sol";
import {IRecipe} from "../src/interfaces/IRecipe.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import { Oracle } from "../src/interfaces/Oracle.sol";

interface Cheats {
    function deal(address who, uint256 amount) external;
    function startPrank(address sender) external;
    function stopPrank() external;
}

contract LiquidationControllerTest_baoETH is Test {
    LiquidationController_baoETH controller;
    IERC20 public baoETH;
    ICToken public bdbSTBL;
    address public bSTBL;
    address public bETH;
    ICToken public bdETH;
    ICToken public bdbETH;
    IComptroller public unitroller;
    Constants public const;
    Cheats public cheats;

    Oracle constant oracle = Oracle(0xbCb0a842aF60c6F09827F34841d3A8770995c6e0);

    function setUp() public {
        controller = new LiquidationController_baoETH(0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5);
        const = new Constants();
        cheats = Cheats(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        cheats.deal(address(this), 1000 ether);
        unitroller = IComptroller(const.unitroller_baoETH());
        baoETH = IERC20(const.baoETH());
        bSTBL = const.bSTBL();
        bdbSTBL = const.baoETH_bdbSTBL();
        bdETH = const.baoETH_bdETH();
        bdbETH = const.baoETH_bdbETH();
        bETH = const.bETH();
    }

    // Check if owner was set properly
    function testOwnerAddress() public {
        assertEq(controller.owner(), address(this));
    }

    // Pinned block number where this liquidation is available: 14225453
    function testLiquidation() public {

        //////////////////////////////
        //Create underwater position//
        //////////////////////////////

        //Allow for bSTBL Minting
        cheats.startPrank(unitroller.admin());
        cheats.deal(unitroller.admin(), 1000 ether);
        unitroller._setMintPaused(address(bdbETH), false);
        address[] memory borrowCapsAdds = new address[](1);
        borrowCapsAdds[0] = address(const.baoETH_bdbaoETH());
        uint256[] memory borrowCapsAmounts = new uint256[](1);
        borrowCapsAmounts[0] = 2**256 - 1;
        unitroller._setMarketBorrowCaps(borrowCapsAdds, borrowCapsAmounts);
        cheats.stopPrank();

        //depositCollateralETH(bdETH, 0.1 ether, false);

        //Mint bSTBL
        mintBasket(bETH, 10 ether);

        //Deposit bSTBL
        uint bETHBalance = IERC20(bETH).balanceOf(address(this));
        depositCollateral(bdbETH, bETHBalance, true);
        uint bETHBalance2 = IERC20(bETH).balanceOf(address(this));

        emit log_named_uint("bETHBalance: ",  bETHBalance);
        emit log_named_uint("bETHBalance2: ", bETHBalance2);

        //Borrow bUSD
        (,uint borrowingPowerBefore,) = unitroller.getAccountLiquidity(address(this));
        emit log_named_uint("borrowingPower 1: ", borrowingPowerBefore);
        uint baoETHBalanceBefore = baoETH.balanceOf(address(this));
        emit log_named_uint("baoETH balance 1: ", baoETHBalanceBefore);
        borrowAssets(const.baoETH_bdbaoETH(), borrowingPowerBefore);
        borrowAssets(const.baoETH_bdbaoETH(), 9 ether);
	(,uint borrowingPowerAfter,) = unitroller.getAccountLiquidity(address(this));
        emit log_named_uint("borrowingPower 2: ", borrowingPowerAfter);
        uint baoETHBalanceAfter = baoETH.balanceOf(address(this));
        emit log_named_uint("baoETH balance 2: ", baoETHBalanceAfter);

        uint bETH_price1 = oracle.getUnderlyingPrice(address(bdbETH));

        //Remove assets from bSTBL to create shortfall
        uint wstETHBalance = IERC20(const.wstETH()).balanceOf(address(bETH));
        transferBasketAssets(const.wstETH(), address(this), wstETHBalance/2);
        uint wstETHBalance2 = IERC20(const.aUSDC()).balanceOf(address(bSTBL));
        (,,uint debtAmount) = unitroller.getAccountLiquidity(address(this));

        uint bETH_price2 = oracle.getUnderlyingPrice(address(bdbETH));

        emit log_named_uint("bETH price before shortfall: ", bETH_price1);
        emit log_named_uint("bETH price after  shortfall: ", bETH_price2);
        emit log_named_uint("wstETHBalance: ",  wstETHBalance);
        emit log_named_uint("wstETHBalance2: ", wstETHBalance2);
        emit log_named_uint("debtAmount: ", debtAmount);
        emit log_named_uint("DAI balance before liq:", ERC20(const.DAI()).balanceOf(address(this)));

        controller.executeLiquidations(
            address(this),
            debtAmount,
            address(bdbETH),
            debtAmount*105e16/1e18,
            address(this)
        );

        emit log_named_uint("DAI balance after liq:", ERC20(const.DAI()).balanceOf(address(this)));
    }

    function mintBasket(address _basket, uint _mintAmount) public {
	IRecipe recipe = IRecipe(const.bETH_recipe());
        uint256 mintPrice = recipe.getPrice(_basket, _mintAmount);
        cheats.deal(address(this), 1000 ether);
        emit log_named_uint("mintPrice:", mintPrice);
        //Mint Basket tokens
	recipe.toBasket{value: mintPrice}(_basket, _mintAmount);
    }

    function depositCollateral(ICToken _dbToken, uint _collateralAmount, bool _joinMarket) public {
        IERC20 underlyingToken = IERC20(_dbToken.underlying());
        underlyingToken.approve(address(_dbToken),_collateralAmount);
        _dbToken.mint(_collateralAmount, _joinMarket);
   }

    function depositCollateralETH(ICToken _dbToken, uint _collateralAmount, bool _joinMarket) public {
        _dbToken.mint{value: _collateralAmount}(_joinMarket);
   }

   function borrowAssets(ICToken _borrowAsset, uint _borrowAmount) public {
        _borrowAsset.borrow(_borrowAmount);
    }

    function transferBasketAssets(address _assetToMove, address _receiver, uint _amount) public {
        //cheats.startPrank(const.bSTBL());
    	cheats.startPrank(const.bETH());
        IERC20(_assetToMove).transfer(_receiver,_amount);
        cheats.stopPrank();
    }

    receive() external payable {}
}
