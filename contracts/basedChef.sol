// SPDX-License-Identifier: ...

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SafeCast.sol";

import "./IBasedStake.sol";

pragma solidity ^0.8.20;

interface IRewarder {
    function onReward(
        uint256 pid,
        address user,
        address recipient,
        uint256 rewardAmount,
        uint256 newLpAmount
    ) external;

    function pendingTokens(
        uint256 pid,
        address user,
        uint256 rewardAmount
    ) external view returns (IERC20[] memory, uint256[] memory);
}

contract zeBASED is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    //   using SafeERC20 for IWETH;

    uint256 private constant MAX_REWARD_PER_SECOND = 100 ether;
    uint256 private constant MAX_ALLOCT_POINT = 1e6;

    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
        uint256 lastDepositTime; // Last deposit time for calculating penalties.
        uint256 stakeStartTime;
        uint256 lockEndTime; // Timestamp when the user's stake is locked until.
        uint256 penaltyEndTime;
    }

    struct UserDetails {
        uint256 amountStaked;
        uint256 pendingReward;
        uint256 stakeStartTime;
        uint256 lockEndTime;
        uint256 timeStaked;
        uint256 remainingWithdrawalPenaltyTime;
        uint256 potentialPenaltyAmount;
        bool isWithdrawalPenaltyActive;
    }

    struct PoolInfo {
        uint128 accRewardPerShare;
        uint64 lastRewardTime;
        uint64 allocPoint;
        bool staking;
        uint256 maxStake;
        uint256 rewardsStartTime;
    }

    PoolInfo[] public poolInfo;
    IERC20[] public lpToken;

    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    //IPool public immutable basedPool;
    IBasedStake public immutable basedStake;
    IERC20 public rewardToken;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    /// @dev Tokens added
    mapping(address => bool) public addedTokens;
    mapping(address => bool) public userStakePreference;

    uint256 public totalAllocPoint;

    uint256 public rewardPerBlock;
    uint256 private constant ACC_REWARD_PRECISION = 1e12;

    uint256 public withdrawPenaltyRate; //10 for a 10% penalty
    uint256 public withdrawPenaltyTime;

    address public liquidityPenaltyReceiver;
    address public based_ETH_LP;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           events                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        IRewarder indexed rewarder
    );
    event LogSetPool(
        uint256 indexed pid,
        uint256 allocPoint,
        IRewarder indexed rewarder,
        bool overwrite
    );
    event LogUpdatePool(
        uint256 indexed pid,
        uint64 lastRewardTime,
        uint256 lpSupply,
        uint256 accRewardPerShare
    );
    event LogRewardPerBlock(uint256 rewardPerBlock);

    event PenaltySettingsChanged(uint256 penaltyRate, uint256 penaltyTime);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      constructor                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    constructor(
        /*address _basedPool,*/
        /* address _basedStake,*/
        address _rewardToken
    ) Ownable(msg.sender) {
        // basedPool = IPool(_basedPool);
        //  basedStake = IBasedStake(_basedStake);
        rewardToken = IERC20(_rewardToken);
        withdrawPenaltyRate = 10; // 10%
        withdrawPenaltyTime = 96 hours; // 96 hour/ 4day penalty base setting
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONFIG                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setStakePreference(bool _wantStake) external {
        userStakePreference[msg.sender] = _wantStake;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _staking Reward will be staked
    /// @param _rewarder Address of the rewarder delegate.
    function add(
        uint256 allocPoint,
        IERC20 _lpToken,
        bool _staking,
        IRewarder _rewarder,
        uint256 _rewardsStartTime,
        uint256 _maxStake
    ) public onlyOwner {
        require(addedTokens[address(_lpToken)] == false, "Token already added");
        require(allocPoint <= MAX_ALLOCT_POINT, "Alloc point too high");
        totalAllocPoint = totalAllocPoint + allocPoint;
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(
            PoolInfo({
                allocPoint: uint64(allocPoint),
                lastRewardTime: uint64(block.timestamp),
                accRewardPerShare: 0,
                staking: _staking,
                maxStake: _maxStake,
                rewardsStartTime: _rewardsStartTime
            })function getPoolInfo(uint256 _pid)
            public
            view
            returns (
                address lpToken,
                uint256 allocPoint,
                IRewarderV2 rewarder,
                uint256 lastRewardTime,
                uint256 accBananaPerShare,
                uint256 totalStaked,
                uint16 depositFeeBP
            )
        {
            return (
                address(poolInfo[_pid].stakeToken),
                poolInfo[_pid].allocPoint,
                poolInfo[_pid].rewarder,
                poolInfo[_pid].lastRewardTime,
                poolInfo[_pid].accBananaPerShare,
                poolInfo[_pid].totalStaked,
                poolInfo[_pid].depositFeeBP
            );
        }
    }

    /// @notice Update the given pool's REWARD allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _staking Reward will be staked
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _staking,
        IRewarder _rewarder,
        //uint256 _rewardsStartTime,
        bool overwrite
    ) public onlyOwner {
        require(_allocPoint <= MAX_ALLOCT_POINT, "Alloc point too high");
        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        poolInfo[_pid].allocPoint = uint64(_allocPoint);
        poolInfo[_pid].staking = _staking;
        if (overwrite) {
            rewarder[_pid] = _rewarder;
        }
        emit LogSetPool(
            _pid,
            _allocPoint,
            overwrite ? _rewarder : rewarder[_pid],
            overwrite
        );
    }

    function updateMaxCapacity(uint256 pid, uint256 _maxStake)
        public
        onlyOwner
    {
        PoolInfo storage pool = poolInfo[pid];
        pool.maxStake = _maxStake;
        emit MaxStakeUpdated(pid, _maxStake);
    }

    event MaxStakeUpdated(uint256 indexed pid, uint256 maxStake);

    function setWithdrawPenalty(uint256 _penaltyRate, uint256 _penaltyTime)
        external
        onlyOwner
    {
        require(_penaltyRate <= 100, "Invalid penalty rate"); //rate can't be over 100%
        withdrawPenaltyRate = _penaltyRate;
        withdrawPenaltyTime = _penaltyTime;
        emit PenaltySettingsChanged(_penaltyRate, _penaltyTime);
    }

    function setLiquidityPenaltyReceiver(address _liquidityPenaltyReceiver)
        external
        onlyOwner
    {
        require(_liquidityPenaltyReceiver != address(0), "Invalid address");
        liquidityPenaltyReceiver = _liquidityPenaltyReceiver;
    }


    function initRewards(uint256 _pid, uint256 _rewardsStartTime)
        external
        onlyOwner
    {
        require(_rewardsStartTime > block.timestamp, "past start time");
        require(
            poolInfo[_pid].rewardsStartTime == 0 ||
                poolInfo[_pid].rewardsStartTime > block.timestamp,
            "pool initialization already set"
        );
        poolInfo[_pid].rewardsStartTime = _rewardsStartTime;
    }


    /// @notice Sets the reward per second to be distributed. Can only be called by the owner.
    /// @param _rewardPerBlock The amount of BASED to be distributed per second.
    function setRewardPerBlock(uint256 _rewardPerBlock) public onlyOwner {
        require(
            _rewardPerBlock <= MAX_REWARD_PER_SECOND,
            "> MAX_REWARD_PER_SECOND"
        );
        rewardPerBlock = _rewardPerBlock;
        emit LogRewardPerBlock(_rewardPerBlock);
    }


    function setAutoLPAddress(address _based_ETH_LP) external onlyOwner {
        based_ETH_LP = _based_ETH_LP;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      VIEW/READINGS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice View function to see pending REWARD on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending BASED reward for a given user.
    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending)
    {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 time = block.timestamp - pool.lastRewardTime;
            accRewardPerShare =
                accRewardPerShare +
                ((time *
                    rewardPerBlock *
                    pool.allocPoint *
                    ACC_REWARD_PRECISION) /
                    totalAllocPoint /
                    lpSupply);
        }
        pending = uint256(
            int256((user.amount * accRewardPerShare) / ACC_REWARD_PRECISION) -
                user.rewardDebt
        );
    }


    function calculateReward(uint256 pid, address userAddress)
        public
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][userAddress];
        uint256 stakeDuration = block.timestamp - user.stakeStartTime;
        uint256 rewardMultiplier = getRewardMultiplier(stakeDuration);

        uint256 calculatedPendingReward = ((user.amount *
            pool.accRewardPerShare) / ACC_REWARD_PRECISION) -
            uint256(user.rewardDebt);
        return (calculatedPendingReward * rewardMultiplier) / 100; // Assuming rewardMultiplier is a percentage
    }


    function getPoolInfo(uint256 _pid)
    public
    view
    returns (
        address lpTokenAddress,
        uint256 allocPoint,
        uint256 lastRewardTime,
        uint256 accRewardPerShare,
        uint256 maxStake,
        uint256 rewardsStartTime,
        bool stakingActive
    )
{
    PoolInfo storage pool = poolInfo[_pid];
    return (
        address(lpToken[_pid]), // Assuming lpToken is an array of IERC20 tokens
        pool.allocPoint,
        pool.lastRewardTime,
        pool.accRewardPerShare,
        pool.maxStake,
        pool.rewardsStartTime, // The start time for rewards for this pool
        pool.staking // Indicates if staking is active for this pool
    );
}

    function getUserStakeInfo(uint256 pid, address userAddress)
        external
        view
        returns (
            uint256 amountStaked,
            uint256 stakeStartTime,
            //  uint256 lockEndTime,
            uint256 penaltyRate
        )
    {
        UserInfo storage user = userInfo[pid][userAddress];
        amountStaked = user.amount;
        stakeStartTime = user.stakeStartTime;
        // lockEndTime = user.lockEndTime;
        penaltyRate = withdrawPenaltyRate;
    }

    function getExtraUserDetails(uint256 pid, address userAddress)
        external
        view
        returns (UserDetails memory userDetails)
    {
        UserInfo storage user = userInfo[pid][userAddress];
        PoolInfo storage pool = poolInfo[pid];
        uint256 currentTimestamp = block.timestamp;
        uint256 pendingReward = this.pendingReward(pid, userAddress);

        //time staked and potential penalty
        uint256 timeStaked = currentTimestamp - user.stakeStartTime;
        uint256 remainingWithdrawalPenaltyTime = 0;
        uint256 potentialPenaltyAmount = 0;
        bool isWithdrawalPenaltyActive = false;

        if (currentTimestamp < user.penaltyEndTime) {
            remainingWithdrawalPenaltyTime =
                user.penaltyEndTime -
                currentTimestamp;
            potentialPenaltyAmount = (user.amount * withdrawPenaltyRate) / 100;
            isWithdrawalPenaltyActive = true;
        }

        //userDetails struct reading
        userDetails.amountStaked = user.amount;
        userDetails.pendingReward = pendingReward;
        userDetails.stakeStartTime = user.stakeStartTime;
        userDetails.lockEndTime = user.lockEndTime;
        userDetails.timeStaked = timeStaked;
        userDetails
            .remainingWithdrawalPenaltyTime = remainingWithdrawalPenaltyTime;
        userDetails.potentialPenaltyAmount = potentialPenaltyAmount;
        userDetails.isWithdrawalPenaltyActive = isWithdrawalPenaltyActive;

        return userDetails;
    }

    function getStakingRecord(uint256 pid, address userAddress)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[pid][userAddress];
        return block.timestamp - user.stakeStartTime; // duration in seconds
    }

    function getRemainingWithdrawPenaltyTime(uint256 pid, address userAddress)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[pid][userAddress];
        if (block.timestamp >= user.penaltyEndTime) {
            return 0; //penalty period ended
        }
        return user.penaltyEndTime - block.timestamp; //remaining
    }

    //get potential withdrawal penalty info
    function getWithdrawalPenalty(uint256 pid, address userAddress)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[pid][userAddress];
        if (block.timestamp < user.lockEndTime) {
            uint256 penaltyAmount = (user.amount * withdrawPenaltyRate) / 10000;
            return penaltyAmount;
        }
        return 0;
    }

    function getRewardMultiplier(uint256 stakeDuration)
        public
        pure
        returns (uint256)
    {
        uint256 oneMonthInSeconds = 30 days;
        if (stakeDuration >= 365 days) {
            // 1 year
            return 500; // 500% for 1 year +
        } else if (stakeDuration >= 6 * oneMonthInSeconds) {
            return 250; // 250% for 6 months +
        } else if (stakeDuration >= 1 * oneMonthInSeconds) {
            return 120; // 120% for 1 month +
        }
        return 100;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  OPERATION // UPDATES                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.timestamp > pool.lastRewardTime) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply != 0) {
                uint256 time = block.timestamp - pool.lastRewardTime;
                pool.accRewardPerShare =
                    pool.accRewardPerShare +
                    uint128(
                        (time *
                            rewardPerBlock *
                            pool.allocPoint *
                            ACC_REWARD_PRECISION) /
                            totalAllocPoint /
                            lpSupply
                    );
            }
            pool.lastRewardTime = uint64(block.timestamp);
            poolInfo[pid] = pool;
            emit LogUpdatePool(
                pid,
                pool.lastRewardTime,
                lpSupply,
                pool.accRewardPerShare
            );
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STAKING                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Deposit LP tokens to MCV2 for REWARD allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    function deposit(uint256 pid, uint256 amount) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 newAmount = user.amount + amount;

        require(
            newAmount <= pool.maxStake,
            "Deposit exceeds max stake for this pool"
        );

        user.stakeStartTime = block.timestamp;
        user.amount = user.amount + amount;
        user.rewardDebt =
            user.rewardDebt +
            int256((amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        user.lastDepositTime = block.timestamp; //update the last deposit time

        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount);
    }


    /// @notice Withdraw LP tokens from MCV2 without harvesting rewards.
    // (optional for country regulations counting auto harvest as taxable events)
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    function withdraw(uint256 pid, uint256 amount) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        require(user.amount >= amount, "withdraw: not good");
        require(amount > 0, "withdraw: amount must be greater than 0");

        // apply the withdrawal penalty if applicable
        uint256 penaltyAmount = 0;
        if (block.timestamp < user.lastDepositTime + withdrawPenaltyTime) {
            penaltyAmount = (amount * withdrawPenaltyRate) / 100;
            // transfer penalty amount to the liquidityPenaltyReceiver multi-sig
            if (penaltyAmount > 0) {
                lpToken[pid].safeTransfer(
                    liquidityPenaltyReceiver,
                    penaltyAmount
                );
            }
        }

        user.stakeStartTime = block.timestamp;
        user.rewardDebt =
            user.rewardDebt -
            int256((amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        user.amount = user.amount - amount;

        // transfer amount after penalty to the user
        amount -= penaltyAmount;
        lpToken[pid].safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, pid, amount);
    }
    

    /// @notice Harvest proceeds for transaction sender.
    /// @param pid The index of the pool. See `poolInfo`.
    function harvest(uint256 pid) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 reward = calculateReward(pid, msg.sender);
        safeRewardTransfer(msg.sender, reward);
        int256 accumulatedReward = int256(
            (user.amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION
        );
        uint256 _pendingReward = uint256(accumulatedReward - user.rewardDebt);

        user.rewardDebt = accumulatedReward;

        if (_pendingReward != 0) {
            _transferReward(
                msg.sender,
                _pendingReward,
                pool.staking && userStakePreference[msg.sender]
            );
        }

        emit Harvest(msg.sender, pid, _pendingReward);
    }

    function safeRewardTransfer(address to, uint256 amount) internal {
        uint256 rewardTokenBalance = rewardToken.balanceOf(address(this));
        if (amount > rewardTokenBalance) {
            rewardToken.safeTransfer(to, rewardTokenBalance);
        } else {
            rewardToken.safeTransfer(to, amount);
        }
    }

    /// @notice Withdraw LP tokens from MCV2 and harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    function withdrawAndHarvest(uint256 pid, uint256 amount) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        require(user.amount >= amount, "withdrawAndHarvest: not good");
        require(
            amount > 0,
            "withdrawAndHarvest: amount must be greater than 0"
        );

        // calculate and apply withdrawal penalty
        uint256 penaltyAmount = 0;
        if (block.timestamp < user.lastDepositTime + withdrawPenaltyTime) {
            penaltyAmount = (amount * withdrawPenaltyRate) / 100;
            //transfer penalty amount to the liquidityPenaltyReceiver multi-sig
            if (penaltyAmount > 0) {
                lpToken[pid].safeTransfer(
                    liquidityPenaltyReceiver,
                    penaltyAmount
                );
            }
        }

        // harvest rewards before applying the penalty
        int256 accumulatedReward = int256(
            (user.amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION
        );
        uint256 _pendingReward = uint256(accumulatedReward - user.rewardDebt);

        user.rewardDebt =
            accumulatedReward -
            int256((amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        user.amount = user.amount - amount;

        if (_pendingReward != 0) {
            _transferReward(msg.sender, _pendingReward, pool.staking);
        }

        // transfer amount after penalty to the user
        amount -= penaltyAmount;
        lpToken[pid].safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, pid, amount);
        if (_pendingReward > 0) {
            emit Harvest(msg.sender, pid, _pendingReward);
        }
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(
            msg.sender,
            pid,
            amount /* , to*/
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         INTERNAL                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _deposit(
        uint256 pid,
        uint256 amount,
        address to
    ) internal {
        require(amount != 0, "Invalid deposit amount");
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        user.amount = user.amount + amount;
        user.rewardDebt =
            user.rewardDebt +
            int256((amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION);

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onReward(pid, msg.sender, to, 0, user.amount);
        }
        emit Deposit(
            msg.sender,
            pid,
            amount /*, to*/
        );
    }

    function _withdrawAndHarvest(
        uint256 pid,
        uint256 amount,
        address to
    ) internal {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedReward = int256(
            (user.amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION
        );
        uint256 _pendingReward = uint256(accumulatedReward - user.rewardDebt);

        user.rewardDebt =
            accumulatedReward -
            int256((amount * pool.accRewardPerShare) / ACC_REWARD_PRECISION);
        user.amount = user.amount - amount;

        if (_pendingReward != 0) {
            _transferReward(to, _pendingReward, pool.staking);
            emit Harvest(msg.sender, pid, _pendingReward);
        }

        IRewarder _rewarder = rewarder[pid];
        if (address(_rewarder) != address(0)) {
            _rewarder.onReward(
                pid,
                msg.sender,
                to,
                _pendingReward,
                user.amount
            );
        }
        emit Withdraw(
            msg.sender,
            pid,
            amount /*, to*/
        );
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-based-calls
        (bool success, ) = to.call{value: amount}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }

    function _transferReward(
        address _to,
        uint256 _amount,
        bool _staking
    ) internal {
        if (_staking && userStakePreference[_to]) {
            rewardToken.safeIncreaseAllowance(address(basedStake), _amount);
            basedStake.stake(_to, _amount);
        } else {
            rewardToken.safeTransfer(_to, _amount);
        }
    }

    receive() external payable {}
}