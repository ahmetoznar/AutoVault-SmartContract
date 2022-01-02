import "./stakeVault.sol";

pragma solidity 0.8.0;

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() internal {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}



pragma solidity 0.8.0;

contract AhmetAutoVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    struct UserInfo {
        uint256 shares; 
        uint256 lastDepositedTime; 
        uint256 tokenAmountAtLastUserAction; 
        uint256 lastUserActionTime; 
        uint256[] userPoolIds;
    }

    struct PoolInformation {
        uint256 blockTimestamp;
        uint256 penaltyEndTimestamp;
        uint256 amount;
        address owner;
    }

    IERC20 public immutable token; 

    IStakingPool public immutable masterchef;

    mapping(address => UserInfo) public userInfo;
    mapping(uint256 => PoolInformation) public poolInfo;
    mapping(uint256 => bool) public availablePools;

    uint256 public totalShares;
    uint256 public lastHarvestedTime;
    address public admin;
    address public treasury;

    uint256 public constant MAX_PERFORMANCE_FEE = 500; // 5%
    uint256 public constant MAX_CALL_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE = 100; // 1%
    uint256 public constant MAX_WITHDRAW_FEE_PERIOD = 72 hours; // 3 days

    uint256 public performanceFee = 200; // 2%
    uint256 public callFee = 25; // 0.25%
    uint256 public withdrawFee = 10; // 0.1%
    uint256 public withdrawFeePeriod = 72 hours; // 3 days

    event Deposit(address indexed sender, uint256 amount, uint256 shares, uint256 lastDepositedTime);
    event Withdraw(address indexed sender, uint256 amount, uint256 shares);
    event Harvest(address indexed sender, uint256 performanceFee, uint256 callFee);
    event Pause();
    event Unpause();


    constructor(
        IERC20 _token,
        IStakingPool _masterchef,
        address _admin,
        address _treasury
    ) {
        token = _token;
        masterchef = _masterchef;
        admin = _admin;
        treasury = _treasury;
        IERC20(_token).safeApprove(address(_masterchef), 9999999999999999999999999999999);
    }

   
    modifier onlyAdmin() {
        require(msg.sender == admin, "admin: wut?");
        _;
    }

   
    modifier notContract() {
        require(!_isContract(msg.sender), "contract not allowed");
        require(msg.sender == tx.origin, "proxy contract not allowed");
        _;
    }

    function getUserInfo(address _user)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256[] memory
        )
    {
        UserInfo storage user = userInfo[_user];
        return (user.shares, user.lastDepositedTime, user.tokenAmountAtLastUserAction, user.lastUserActionTime, user.userPoolIds);
    }



    function getUserPoolInfo(uint256 _poolId)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            address
        )
    {
        PoolInformation storage _poolInfo = poolInfo[_poolId];
        return (
            _poolInfo.blockTimestamp,
            _poolInfo.penaltyEndTimestamp,
            _poolInfo.amount,
            _poolInfo.owner
        );
    }




    function deposit(uint256 _amount) external whenNotPaused notContract {
        require(_amount > 0, "Nothing to deposit");

         uint256 randomPoolId =
            uint256(
                keccak256(
                    abi.encodePacked(
                        msg.sender,
                        block.timestamp,
                        block.number,
                        _amount
                    )
                )
            );
        require(!availablePools[randomPoolId], "Pool id already created");
        
        uint256 pool = balanceOf(); //returns the token amount in AutoVault + MasterChef
        token.safeTransferFrom(msg.sender, address(this), _amount); //Get tokens to contract
        uint256 currentShares = 0; //Define current shares
        if (totalShares != 0) {
            currentShares = (_amount.mul(totalShares)).div(pool); //Find the exact amount to be deposited.
        } else {
            currentShares = _amount; //Define current shares as first deposit
        }
        UserInfo storage user = userInfo[msg.sender]; //Reach to data of user via struct
        PoolInformation storage _poolInfo = poolInfo[randomPoolId];
        //process the pool datas
        availablePools[randomPoolId] = true;
        _poolInfo.blockTimestamp = block.timestamp;
        _poolInfo.amount = _amount;
        _poolInfo.owner = msg.sender;
        _poolInfo.penaltyEndTimestamp = block.timestamp.add(
            withdrawFeePeriod
        );
        user.userPoolIds.push(randomPoolId);

        user.shares = user.shares.add(currentShares); //Update total deposited amount for user
        user.lastDepositedTime = block.timestamp; // Update last deposit date

        totalShares = totalShares.add(currentShares); //Update total deposited value

        user.tokenAmountAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares); //Update deposited last amount
        user.lastUserActionTime = block.timestamp; // Update last process date

        _earn(); //stake the tokens at 

        emit Deposit(msg.sender, _amount, currentShares, block.timestamp); //emit tx
    }

  
    function withdrawAll() external notContract {
        
        UserInfo storage user = userInfo[msg.sender]; //reach to user datas.
        
        uint256 withdrawAmount = user.shares;
        require(withdrawAmount > 0 , "nothing to withdraw");
        uint256 currentAmount = (balanceOf().mul(withdrawAmount)).div(totalShares); //exact amount to be withdrawed.
        user.shares = user.shares.sub(withdrawAmount); //deduct the token amount user has 
        totalShares = totalShares.sub(withdrawAmount); //decrease the total staked amount
       
        
        uint256 bal = available(); //token amount of AutoVault
        uint256 totalAmountToBeTransfer = 0;

          if (bal < currentAmount) { //if the lesser than the amount that user want to withdraw, 
            uint256 balWithdraw = currentAmount.sub(bal); //find the how much token AutoVaults needs.
            IStakingPool(masterchef).withdrawStake(balWithdraw); //Get enough token from MasterChef 
            uint256 balAfter = available(); //get the balance of AutoVault again
            uint256 diff = balAfter.sub(bal); //check the withdrawed token amount.
            if (diff < balWithdraw) { // If the diffrent is more than withdrawed value.
                currentAmount = bal.add(diff); //Update the value that user want the withdraw.
            }
        }

    
        if(IStakingPool(masterchef).finishBlock() > block.number){
        //!ATTENTION FOR GAS FEE
        for (uint8 index = 0; index < user.userPoolIds.length; index++ ){
            PoolInformation storage _poolInfo = poolInfo[user.userPoolIds[index]]; //reach deposit info
            uint256 withdrawAmountForPool = _poolInfo.amount;

        if (block.timestamp < _poolInfo.penaltyEndTimestamp) { //check penalty expire date
            uint256 currentWithdrawFee = withdrawAmountForPool.mul(withdrawFee).div(10000);
            withdrawAmountForPool = withdrawAmountForPool.sub(currentWithdrawFee); //deduct fee
            totalAmountToBeTransfer = totalAmountToBeTransfer.add(withdrawAmountForPool);
        }else{
            totalAmountToBeTransfer = totalAmountToBeTransfer.add(withdrawAmountForPool);
        }
        
        _poolInfo.amount = 0;
        }
        }else{
        totalAmountToBeTransfer = currentAmount;
        }

        if(currentAmount.sub(totalAmountToBeTransfer) != 0){
        token.safeTransfer(treasury, currentAmount.sub(totalAmountToBeTransfer)); //send fee amount to treasury 
        }

        if (user.shares > 0) { // Check user's deposited value
            user.tokenAmountAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares); //User's deposited value
        } else {
            user.tokenAmountAtLastUserAction = 0;
        }
        user.lastUserActionTime = block.timestamp; // Update last process date

        token.safeTransfer(msg.sender, totalAmountToBeTransfer);

    }

     
    function harvest() external notContract whenNotPaused {
        IStakingPool(masterchef).withdrawStake(0); //Calculates the reward for msg.sender in masterchef, calculates the reward and transfers it to this contract address. Sends reward tokens to address(this).
        
        uint256 bal = available(); //bu kontrattaki token adedi
        uint256 currentPerformanceFee = bal.mul(performanceFee).div(10000); //calculate fee
        token.safeTransfer(treasury, currentPerformanceFee); //send fee to treasury

        uint256 currentCallFee = bal.mul(callFee).div(10000); //calculate reward of user. These rewards for earn() function.
        token.safeTransfer(msg.sender, currentCallFee);

        _earn(); //stake the pending rewards again.

        lastHarvestedTime = block.timestamp; //update last harvest time

        emit Harvest(msg.sender, currentPerformanceFee, currentCallFee);
    }
  

  
    function setAdmin(address _admin) external onlyOwner {
        require(_admin != address(0), "Cannot be zero address");
        admin = _admin;
    }


    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Cannot be zero address");
        treasury = _treasury;
    }

  
    function setPerformanceFee(uint256 _performanceFee) external onlyAdmin {
        require(_performanceFee <= MAX_PERFORMANCE_FEE, "performanceFee cannot be more than MAX_PERFORMANCE_FEE");
        performanceFee = _performanceFee;
    }

   
    function setCallFee(uint256 _callFee) external onlyAdmin {
        require(_callFee <= MAX_CALL_FEE, "callFee cannot be more than MAX_CALL_FEE");
        callFee = _callFee;
    }

    
    function setWithdrawFee(uint256 _withdrawFee) external onlyAdmin {
        require(_withdrawFee <= MAX_WITHDRAW_FEE, "withdrawFee cannot be more than MAX_WITHDRAW_FEE");
        withdrawFee = _withdrawFee;
    }

   
    function setWithdrawFeePeriod(uint256 _withdrawFeePeriod) external onlyAdmin {
        require(
            _withdrawFeePeriod <= MAX_WITHDRAW_FEE_PERIOD,
            "withdrawFeePeriod cannot be more than MAX_WITHDRAW_FEE_PERIOD"
        );
        withdrawFeePeriod = _withdrawFeePeriod;
    }

   
    function emergencyWithdraw() external onlyAdmin {
        IStakingPool(masterchef).emergencyWithdraw();
    }

    function inCaseTokensGetStuck(address _token) external onlyAdmin {
        require(_token != address(token), "Token cannot be same as deposit token");

        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(msg.sender, amount);
    }


    function pause() external onlyAdmin whenNotPaused {
        _pause();
        emit Pause();
    }

   
    function unpause() external onlyAdmin whenPaused {
        _unpause();
        emit Unpause();
    }

  
    function calculateHarvestCakeRewards() external view returns (uint256) {
        uint256 amount = IStakingPool(masterchef).pendingReward(address(this));
        amount = amount.add(available());
        uint256 currentCallFee = amount.mul(callFee).div(10000);

        return currentCallFee;
    }

   
    function calculateTotalPendingCakeRewards() external view returns (uint256) {
        uint256 amount = IStakingPool(masterchef).pendingReward(address(this));
        amount = amount.add(available());

        return amount;
    }

    function getPricePerFullShare() external view returns (uint256) {
        return totalShares == 0 ? 1e18 : balanceOf().mul(1e18).div(totalShares);
    }

   
    function withdraw(uint256 _shares, uint256 _poolId) public nonReentrant notContract {
        UserInfo storage user = userInfo[msg.sender]; 
        PoolInformation storage _poolInfo = poolInfo[_poolId]; 

        require(_shares > 0, "Nothing to withdraw"); 
        require(_poolInfo.amount >= _shares, "withdraw: not good");
        require(_poolInfo.owner == msg.sender, "you are not owner");
        require(_shares <= user.shares, "Withdraw amount exceeds balance"); 

        //almost same process with withdraw all.
        uint256 currentAmount = (balanceOf().mul(_shares)).div(totalShares); 
        user.shares = user.shares.sub(_shares); 
        totalShares = totalShares.sub(_shares); 
        _poolInfo.amount = _poolInfo.amount.sub(_shares);

        uint256 bal = available(); 
        if (bal < currentAmount) { 
            uint256 balWithdraw = currentAmount.sub(bal); 
            IStakingPool(masterchef).withdrawStake(balWithdraw); 
            uint256 balAfter = available(); 
            uint256 diff = balAfter.sub(bal); 
            if (diff < balWithdraw) {
                currentAmount = bal.add(diff); 
            }
        }

    if(IStakingPool(masterchef).finishBlock() > block.number){
        if (block.timestamp < _poolInfo.penaltyEndTimestamp) {
            uint256 currentWithdrawFee = currentAmount.mul(withdrawFee).div(10000);
            token.safeTransfer(treasury, currentWithdrawFee);
            currentAmount = currentAmount.sub(currentWithdrawFee);
        }
     }

        if (user.shares > 0) { 
            user.tokenAmountAtLastUserAction = user.shares.mul(balanceOf()).div(totalShares); 
        } else {
            user.tokenAmountAtLastUserAction = 0;
        }

        user.lastUserActionTime = block.timestamp; 
        token.safeTransfer(msg.sender, currentAmount); 

        emit Withdraw(msg.sender, currentAmount, _shares);
    }

   
    function available() public view returns (uint256) {
        return token.balanceOf(address(this)); //Token amount at contract, When user run the stake or harvest function, MasterChef send the pending reward to AutoVault smart contract.
    }

   
    function balanceOf() public view returns (uint256) {
        (uint256 amount, ) = IStakingPool(masterchef).userInfo(address(this));
        return token.balanceOf(address(this)).add(amount); // token admount at AutoVault + MasterChef. 
    }

   
    function _earn() internal {
        uint256 bal = available(); //Token amount at contract. 
        if (bal > 0) {
            IStakingPool(masterchef).stakeTokens(bal); //Stake the token balance of AutoVault smart contract to MasterChef. 
        }
    }

    
    function _isContract(address addr) internal view returns (bool) { //Check if the transacting address is the contract address.
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}