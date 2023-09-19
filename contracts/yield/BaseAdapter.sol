pragma solidity ^0.8.19;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

abstract contract BaseAdapter is Owned {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    ERC20 public immutable asset;
    address public rewardRecipient;
    uint public immutable DIVISOR; // This is just a constant to query convertToShares and then divide result, vault.convertToShares(DIVISOR) must never revert
    uint public totalSupply;
    uint public minBalanceToTriggerDeposit;

    constructor(
        address asset_,
        address rewardRecipient_,
        uint minBalanceToTriggerDeposit_
    ) Owned(msg.sender) {
        asset = ERC20(asset_);
        rewardRecipient = rewardRecipient_;
        DIVISOR = 10**asset.decimals(); // Even if decimals() changes later this will still work fine
        minBalanceToTriggerDeposit = minBalanceToTriggerDeposit_;
    }

    function setRewardRecipient(address _rewardRecipient) external onlyOwner() {
        rewardRecipient = _rewardRecipient;
    }

    function setMinBalanceToTriggerDeposit(uint _minBalanceToTriggerDeposit) external onlyOwner() {
        minBalanceToTriggerDeposit = _minBalanceToTriggerDeposit;
    }

    // Why is this not caller-restricted?
    // - forceDeposit() can be triggered anyway by making a deposit that increases balance enough, and then withdrawing it
    // - redeem() doesn't support withdrawing money from both asset and vault, so in the case where the last user wants to withdraw
    //    and only 50% of money is in the vault, owner could increase minBalanceToTriggerDeposit to max to prevent new vault deposits
    //    and prevent the user from getting the money, asking for a ransom. With this method user can simply call this to solve the situation
    function triggerDeposit() external {
        forceDeposit(asset.balanceOf(address(this)));
    }

    function forceDeposit(uint assets) internal virtual;

    function deposit(uint256 assets) internal returns (uint) {
        uint ourShares = totalSupply == 0 ? assets : assets.mulDivDown(totalSupply, totalAssets() - assets);
        totalSupply += ourShares;
        uint assetBalance = asset.balanceOf(address(this));
        if(assetBalance > minBalanceToTriggerDeposit){
            forceDeposit(assetBalance);
        }
        return ourShares;
    }

    function forceRedeem(uint assets, address receiver) internal virtual;

    function redeem(uint256 shares, address receiver) internal {
        uint assets = convertToAssets(shares);
        totalSupply -= shares;
        if(assets <= asset.balanceOf(address(this))){
            asset.safeTransfer(receiver, assets);
        } else {
            forceRedeem(assets, receiver);
        }
    }

    function totalAssets() public view virtual returns (uint256);

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? assets : assets.mulDivDown(supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply);
    }

    function refreshApproval() external virtual;
}