// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {BoringBatchable} from "./fork/BoringBatchable.sol";

interface IERC4626 {
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function balanceOf(address owner) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function transfer(address to, uint256 value) external returns (bool);
}

contract Subs is BoringBatchable {
    using SafeTransferLib for ERC20;

    uint40 public currentPeriod;
    uint40 public immutable periodDuration;
    ERC20 public immutable token;
    IERC4626 public immutable vault;
    address public immutable feeCollector;
    uint public immutable DIVISOR;
    uint public sharesAccumulator;
    mapping(address => mapping(uint256 => uint256)) public receiverAmountToExpire;
    struct ReceiverBalance {
        uint256 balance;
        uint256 amountPerPeriod;
        uint40 lastUpdate;
    }
    mapping(address => ReceiverBalance) public receiverBalances;
    mapping(uint256 => uint256) public sharesPerPeriod;
    mapping(bytes32 => bool) public subs;

    event NewSubscription(address owner, address receiver, uint amountPerCycle, uint expiration, uint initialShares);

    constructor(uint40 _periodDuration, address _token, address _vault, address _feeCollector, uint _divisor){
        periodDuration = _periodDuration;
        token = ERC20(_token);
        vault = IERC4626(_vault);
        feeCollector = _feeCollector;
        DIVISOR = _divisor;
    }

    function _updateGlobal() private {
        if(block.timestamp > currentPeriod + periodDuration){
            uint shares = vault.convertToShares(DIVISOR);
            do {
                sharesPerPeriod[currentPeriod] = shares;
                currentPeriod += periodDuration;
                sharesAccumulator += shares; // TODO: reduce this to a single sstore? could just be shares*periodDifference/periodDuration
            } while(block.timestamp > currentPeriod + periodDuration);
        }
    }

    function _updateReceiver(address receiver) private {
        _updateGlobal();
        ReceiverBalance storage bal = receiverBalances[receiver];
        while(bal.lastUpdate < block.timestamp){
            bal.amountPerPeriod -= receiverAmountToExpire[receiver][bal.lastUpdate];
            bal.balance += bal.amountPerPeriod * sharesPerPeriod[bal.lastUpdate];
            bal.lastUpdate += periodDuration;
        }
    }

    function getSubId(address owner, uint initialPeriod, uint expirationDate, uint amountPerCycle, address receiver, uint256 accumulator, uint256 initialShares) public pure returns (bytes32 id){
        id = keccak256(
            abi.encode(
                owner,
                initialPeriod,
                expirationDate, // needed to undo receiverAmountToExpire
                amountPerCycle,
                receiver,
                accumulator,
                initialShares
            ) // TODO: Is nonce needed
        );
    }

    function subscribe(address receiver, uint amountPerCycle, uint256 cycles) external {
        _updateReceiver(receiver);
        uint claimableThisPeriod = (amountPerCycle * (currentPeriod - block.timestamp)) / periodDuration;
        uint amountForFuture = amountPerCycle * cycles;
        uint amount = amountForFuture + claimableThisPeriod;
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint shares = vault.deposit(amount, address(this));
        uint expiration = currentPeriod + periodDuration*cycles;
        receiverAmountToExpire[receiver][expiration] += amountPerCycle;
        receiverBalances[receiver].amountPerPeriod += amountPerCycle;
        receiverBalances[receiver].balance += (shares * claimableThisPeriod) / amount;
        uint sharesLeft = (amountForFuture * shares) / amount;
        subs[getSubId(msg.sender, currentPeriod, expiration, amountPerCycle, receiver, sharesAccumulator, sharesLeft)] = true; // TODO: sub can be overwritten!
        emit NewSubscription(msg.sender, receiver, amountPerCycle, expiration, sharesLeft);
    }

    function unsubscribe(uint initialPeriod, uint expirationDate, uint amountPerCycle, address receiver, uint256 accumulator, uint256 initialShares) external {
        _updateGlobal();
        bytes32 subId = getSubId(msg.sender, initialPeriod, expirationDate, amountPerCycle, receiver, accumulator, initialShares);
        require(subs[subId] == true);
        subs[subId] = false;
        if(expirationDate > block.timestamp){
            uint sharesPaid = (sharesAccumulator - accumulator) * amountPerCycle;
            uint sharesLeft = initialShares - sharesPaid;
            vault.redeem(sharesLeft, msg.sender, address(this));
            receiverAmountToExpire[receiver][expirationDate] -= amountPerCycle;
            receiverAmountToExpire[receiver][currentPeriod] += amountPerCycle;
        } else {
            while(initialPeriod < expirationDate){
                initialShares -= sharesPerPeriod[initialPeriod] * amountPerCycle;
                initialPeriod += periodDuration;
            }
            vault.redeem(initialShares, msg.sender, address(this));
        }
    }

    function claim(uint256 amount) external {
        _updateReceiver(msg.sender);
        receiverBalances[msg.sender].balance -= amount;
        vault.redeem((amount * 99) / 100, msg.sender, address(this));
        vault.transfer(feeCollector, amount / 100);
    }
}