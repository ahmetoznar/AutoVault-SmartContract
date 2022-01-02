pragma solidity 0.8.0;

interface IStakingPool {
    function stakeTokens(uint256 _amountToStake) external;

    function withdrawStake(uint256 _amount) external;

    function pendingReward(address _user) external view returns (uint256);

    function finishBlock() external view returns (uint256);

    function userInfo(address _user) external view returns (uint256, uint256);

    function emergencyWithdraw() external;

}