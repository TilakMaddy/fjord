pragma solidity =0.8.21;
import { ERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from
    "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { SafeMath } from "lib/openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
import { IFjordPoints } from "./interfaces/IFjordPoints.sol";
contract FjordPoints is ERC20, ERC20Burnable, IFjordPoints {
    using SafeMath for uint256;
    error InvalidAddress();
    error DistributionNotAllowedYet();
    error NotAuthorized();
    error UnstakingAmountExceedsStakedAmount();
    error TotalStakedAmountZero();
    error CallerDisallowed();
    address public owner;
    address public staking;
    uint256 public constant EPOCH_DURATION = 1 weeks;
    uint256 public lastDistribution;
    uint256 public totalStaked;
    uint256 public pointsPerToken;
    uint256 public totalPoints;
    uint256 public pointsPerEpoch;
    struct UserInfo {
        uint256 stakedAmount;
        uint256 pendingPoints;
        uint256 lastPointsPerToken;
    }
    mapping(address => UserInfo) public users;
    uint256 public constant PRECISION_18 = 1e18;
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event PointsDistributed(uint256 points, uint256 pointsPerToken);
    event PointsClaimed(address indexed user, uint256 amount);
    constructor() ERC20("BjordBoint", "BJB") {
        owner = msg.sender;
        lastDistribution = block.timestamp;
        pointsPerEpoch = 100 ether;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert CallerDisallowed();
        _;
    }
    modifier onlyStaking() {
        if (msg.sender != staking) {
            revert NotAuthorized();
        }
        _;
    }
    modifier updatePendingPoints(address user) {
        UserInfo storage userInfo = users[user];
        uint256 owed = userInfo.stakedAmount.mul(pointsPerToken.sub(userInfo.lastPointsPerToken))
            .div(PRECISION_18);
        userInfo.pendingPoints = userInfo.pendingPoints.add(owed);
        userInfo.lastPointsPerToken = pointsPerToken;
        _;
    }
    modifier checkDistribution() {
        distributePoints();
        _;
    }
    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        owner = _newOwner;
    }
    function setStakingContract(address _staking) external onlyOwner {
        if (_staking == address(0)) {
            revert InvalidAddress();
        }
        staking = _staking;
    }
    function setPointsPerEpoch(uint256 _points) external onlyOwner checkDistribution {
        if (_points == 0) {
            revert();
        }
        pointsPerEpoch = _points;
    }
    function onStaked(address user, uint256 amount)
        external
        onlyStaking
        checkDistribution
        updatePendingPoints(user)
    {
        UserInfo storage userInfo = users[user];
        userInfo.stakedAmount = userInfo.stakedAmount.add(amount);
        totalStaked = totalStaked.add(amount);
        emit Staked(user, amount);
    }
    function onUnstaked(address user, uint256 amount)
        external
        onlyStaking
        checkDistribution
        updatePendingPoints(user)
    {
        UserInfo storage userInfo = users[user];
        if (amount > userInfo.stakedAmount) {
            revert UnstakingAmountExceedsStakedAmount();
        }
        userInfo.stakedAmount = userInfo.stakedAmount.sub(amount);
        totalStaked = totalStaked.sub(amount);
        emit Unstaked(user, amount);
    }
    function distributePoints() public {
        if (block.timestamp < lastDistribution + EPOCH_DURATION) {
            return;
        }
        if (totalStaked == 0) {
            return;
        }
        uint256 weeksPending = (block.timestamp - lastDistribution) / EPOCH_DURATION;
        pointsPerToken =
            pointsPerToken.add(weeksPending * (pointsPerEpoch.mul(PRECISION_18).div(totalStaked)));
        totalPoints = totalPoints.add(pointsPerEpoch * weeksPending);
        lastDistribution = lastDistribution + (weeksPending * 1 weeks);
        emit PointsDistributed(pointsPerEpoch, pointsPerToken);
    }
    function claimPoints() external checkDistribution updatePendingPoints(msg.sender) {
        UserInfo storage userInfo = users[msg.sender];
        uint256 pointsToClaim = userInfo.pendingPoints;
        if (pointsToClaim > 0) {
            userInfo.pendingPoints = 0;
            _mint(msg.sender, pointsToClaim);
            emit PointsClaimed(msg.sender, pointsToClaim);
        }
    }
}
