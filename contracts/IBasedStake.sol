import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity ^0.8.20;

interface IBasedStake {
    function userInfo(address _user)
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        );

    function stake(address _to, uint256 _amount) external;

    function unstake(address _to, uint256 _amount) external;

    function cooldown() external;

    function claimRewards(address _to) external;

    function pendingReward(address _to) external view returns (uint256);

    function BASED() external view returns (IERC20);

    function COOLDOWN_SECONDS() external view returns (uint256);

    function UNSTAKE_WINDOWN() external view returns (uint256);
}