// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./token/BEP20/IBEP20.sol";
import "./token/BEP20/SafeBEP20.sol";
import "./access/Ownable.sol";
import "./libraries/Percentages.sol";
import "./utils/ReentrancyGuard.sol";

contract PartnerPool is Ownable, ReentrancyGuard {
    using SafeBEP20     for IBEP20;
    using Percentages   for uint256;

    bool    public  isInitialized;      // Flag for if the pool is initialized
    uint256 public  accTokenPerShare;   // Accrued token per share
    uint256 public  bonusEndBlock;      // The block number when mining ends.
    uint256 public  startBlock;         // The block number when mining starts
    uint256 public  lastRewardBlock;    // The block number of the last pool update
    uint256 public  rewardPerBlock;     // Tokens rewarded per block
    uint256 public  PRECISION_FACTOR;   // The precision factor
    IBEP20  public  rewardToken;        // The reward token
    IBEP20  public  stakedToken;        // The staked token
    uint256 public  minimumStake;       // Minimum amount of tokens required to stake
    uint256 public  minimumStakingTime; // Duration a user must stake before withdrawal fees are lifted
    address payable treasury;           // The treasury address

    // The burn address
    address public  burnAddr = 0x000000000000000000000000000000000000dEaD;

    // Info of each user that stakes tokens
    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 amount;                     // How many staked tokens the user has provided
        uint256 rewardDebt;                 // Reward debt
        uint256 tokenWithdrawalDate;        // Date user must wait until before early withdrawal fees are lifted.
    }

    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event NewStartAndEndBlocks(uint256 startBlock, uint256 endBlock);
    event NewRewardPerBlock(uint256 rewardPerBlock);
    event RewardsStop(uint256 blockNumber);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawEarly(address indexed user, uint256 amountWithdrawn, uint256 amountLocked);

    // Constructor for constructing things
    constructor(IBEP20 _stakingToken, IBEP20 _rewardToken, address _treasury) {
        stakedToken = IBEP20(_stakingToken);
        rewardToken = IBEP20(_rewardToken);
        treasury = payable(_treasury);

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(decimalsRewardToken < 30, "Must be inferior to 30");

        PRECISION_FACTOR = uint256(10**(uint256(30) - decimalsRewardToken));
    }

    // Initialize the contract after creation
    function initialize(
        uint _rewardPerBlock, 
        uint _startBlock, 
        uint _bonusEndBlock, 
        uint _minimumStake, 
        uint _minimumStakingTime
    ) public onlyOwner() {
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        minimumStake = _minimumStake;
        minimumStakingTime = _minimumStakingTime;
        lastRewardBlock = startBlock;
        isInitialized = true;
    }

    // Modifier to ensure user's withdrawal date has passed before withdrawing
    modifier canWithdraw(uint _amount) {
        uint _withdrawalDate = userInfo[msg.sender].tokenWithdrawalDate;
        require((block.timestamp >= _withdrawalDate && _withdrawalDate > 0) || _amount == 0, 
            'Staking: Token is still locked, use withdrawEarly to withdraw funds before the end of your staking period.');
        _;
    }

    // Function to deposit tokens to be staked
    function deposit(uint256 _amount) external nonReentrant() {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount + _amount >= minimumStake, 'Amount staked must be >= grave minimum stake.');

        _updatePool();

        if (user.amount > 0) {
            uint256 pending = ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;
            if (pending > 0) {
                rewardToken.safeTransfer(address(msg.sender), pending);
            }
        }

        if (_amount > 0) {
            user.tokenWithdrawalDate = block.timestamp + minimumStakingTime;
            user.amount += _amount;
            stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Deposit(msg.sender, _amount);
    }

    // Function to withdraw staked tokens
    function withdraw(uint256 _amount) external nonReentrant() canWithdraw(_amount) {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "Amount to withdraw too high");
        require(
            (user.amount - _amount >= minimumStake) || (user.amount - _amount) == 0,
            'When withdrawing from partner pools the remaining balance must be 0 or >= the minimum stake.'
        );
        _updatePool();

        uint256 pending = ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;

        if (_amount > 0) {
            user.amount -= _amount;
            stakedToken.safeTransfer(address(msg.sender), _amount);
            user.tokenWithdrawalDate = block.timestamp + minimumStakingTime;
        }

        if (pending > 0) {
            rewardToken.safeTransfer(address(msg.sender), pending);
        }

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit Withdraw(msg.sender, _amount);
    }

    // Function to withdraw tokens with an early withdraw tax
    function withdrawEarly(uint256 _amount) external nonReentrant() {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "Amount to withdraw too high");
        require(
            (user.amount - _amount >= minimumStake) || (user.amount - _amount) == 0,
            'When withdrawing from partner pools the remaining balance must be 0 or >= the minimum stake.'
        );

        uint256 _earlyWithdrawalFee = _amount.calcPortionFromBasisPoints(500);
        uint256 _burn = _earlyWithdrawalFee.calcPortionFromBasisPoints(5000);   // Half of zombie is burned
        uint256 _toTreasury = _earlyWithdrawalFee - _burn;                      // The rest is sent to the treasury

        uint256 _remainingAmount = _amount;
        _remainingAmount -= _earlyWithdrawalFee;

        _updatePool();

        uint256 pending = ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;

        if (_amount > 0) {
            user.amount = user.amount - _amount;
            stakedToken.safeTransfer(burnAddr, _burn);
            stakedToken.safeTransfer(treasury, _toTreasury);
            stakedToken.safeTransfer(address(msg.sender), _remainingAmount);
            user.tokenWithdrawalDate = block.timestamp + minimumStakingTime;
        }

        if (pending > 0) {
            rewardToken.safeTransfer(address(msg.sender), pending);
        }

        user.rewardDebt = (user.amount * accTokenPerShare) / PRECISION_FACTOR;

        emit WithdrawEarly(msg.sender, _remainingAmount, _earlyWithdrawalFee);
    }

    // Function to do an emergency withdraw without worrying about pending rewards
    function emergencyWithdraw() external nonReentrant() {
        UserInfo storage user = userInfo[msg.sender];
        uint256 _remaining = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        if(block.timestamp < user.tokenWithdrawalDate) {
            uint256 _earlyWithdrawalFee = _remaining / 20; // 5% of amount
            _remaining -= _earlyWithdrawalFee;
            stakedToken.safeTransfer(treasury, _earlyWithdrawalFee);
        }

        if (_remaining > 0) {
            stakedToken.safeTransfer(address(msg.sender), _remaining);
        }

        emit EmergencyWithdraw(msg.sender, user.amount);
    }

    // Function for the owner to do an emergency recovery of the reward tokens
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner() {
        rewardToken.safeTransfer(address(msg.sender), _amount);
    }

    // Function to recover any random tokens that get sent to the contract
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner() {
        require(_tokenAddress != address(stakedToken), "Cannot be staked token");
        require(_tokenAddress != address(rewardToken), "Cannot be reward token");

        IBEP20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    // Function to stop rewards distribution
    function stopReward() external onlyOwner() {
        bonusEndBlock = block.number;
    }

    // Function to update the rewards per block
    function updateRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner() {
        require(block.number < startBlock, "Pool has started");
        rewardPerBlock = _rewardPerBlock;
        emit NewRewardPerBlock(_rewardPerBlock);
    }

    // Function to update the start/end blocks
    function updateStartAndEndBlocks(uint256 _startBlock, uint256 _bonusEndBlock) external onlyOwner() {
        require(block.number < startBlock, "Pool has started");
        require(_startBlock < _bonusEndBlock, "New startBlock must be lower than new endBlock");
        require(block.number < _startBlock, "New startBlock must be higher than current block");

        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;

        // Set the lastRewardBlock as the startBlock
        lastRewardBlock = startBlock;

        emit NewStartAndEndBlocks(_startBlock, _bonusEndBlock);
    }

    // Function to get the current pending rewards
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));
        if (block.number > lastRewardBlock && stakedTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
            uint256 cakeReward = multiplier * rewardPerBlock;
            uint256 adjustedTokenPerShare =
            accTokenPerShare + ((cakeReward * PRECISION_FACTOR) / stakedTokenSupply);
            return ((user.amount * adjustedTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;
        } else {
            return ((user.amount * accTokenPerShare) / PRECISION_FACTOR) - user.rewardDebt;
        }
    }

    // Function to get the treasury address
    function getTreasury() public view returns(address) {
        return address(treasury);
    }

    // Function to update the pool data
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }

        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));

        if (stakedTokenSupply == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
        uint256 cakeReward = multiplier * rewardPerBlock;
        accTokenPerShare = accTokenPerShare + ((cakeReward * PRECISION_FACTOR) / stakedTokenSupply);
        lastRewardBlock = block.number;
    }

    // Function to get the rewards multiplier
    function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to - _from;
        } else if (_from >= bonusEndBlock) {
            return 0;
        } else {
            return bonusEndBlock - _from;
        }
    }
}