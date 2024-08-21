pragma solidity =0.8.21;
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { ISablierV2Lockup } from "lib/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import { ISablierV2LockupRecipient } from
    "lib/v2-core/src/interfaces/hooks/ISablierV2LockupRecipient.sol";
import { IFjordPoints } from "./interfaces/IFjordPoints.sol";
struct DepositReceipt {
    uint16 epoch;
    uint256 staked;
    uint256 vestedStaked;
}
struct ClaimReceipt {
    uint16 requestEpoch;
    uint256 amount;
}
struct NFTData {
    uint16 epoch;
    uint256 amount;
}
struct UserData {
    uint256 totalStaked;
    uint256 unclaimedRewards;
    uint16 unredeemedEpoch;
    uint16 lastClaimedEpoch;
}
contract FjordStaking is ISablierV2LockupRecipient {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeTransferLib for ERC20;
    event Staked(address indexed user, uint16 indexed epoch, uint256 amount);
    event VestedStaked(
        address indexed user, uint16 indexed epoch, uint256 indexed streamID, uint256 amount
    );
    event RewardAdded(uint16 indexed epoch, address rewardAdmin, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event EarlyRewardClaimed(address indexed user, uint256 rewardAmount, uint256 penaltyAmount);
    event ClaimedAll(address indexed user, uint256 totalRewardAmount, uint256 totalPenaltyAmount);
    event Unstaked(address indexed user, uint16 indexed epoch, uint256 stakedAmount);
    event VestedUnstaked(
        address indexed user, uint16 indexed epoch, uint256 stakedAmount, uint256 streamID
    );
    event UnstakedAll(
        address indexed user,
        uint256 totalStakedAmount,
        uint256[] activeDepositsBefore,
        uint256[] activeDepositsAfter
    );
    event ClaimReceiptCreated(address indexed user, uint16 requestEpoch);
    event RewardPerTokenChanged(uint16 epoch, uint256 rewardPerToken);
    event SablierWithdrawn(address indexed user, uint256 streamID, address caller, uint256 amount);
    event SablierCanceled(address indexed user, uint256 streamID, address caller, uint256 amount);
    error CallerDisallowed();
    error InvalidAmount();
    error UnstakeEarly();
    error ClaimTooEarly();
    error DepositNotFound();
    error ClaimReceiptNotFound();
    error NoActiveDeposit();
    error UnstakeMoreThanDeposit();
    error NotAStream();
    error StreamNotSupported();
    error NotAWarmStream();
    error InvalidAsset();
    error NothingToClaim();
    error StreamOwnerNotFound();
    error InvalidZeroAddress();
    error CompleteRequestTooEarly();
    address public owner;
    ISablierV2Lockup public sablier;
    IFjordPoints public points;
    mapping(address user => mapping(uint16 epoch => DepositReceipt)) public deposits;
    mapping(address user => ClaimReceipt) public claimReceipts;
    mapping(address user => EnumerableSet.UintSet epochIds) private _activeDeposits;
    mapping(address user => mapping(uint256 streamID => NFTData)) private _streamIDs;
    mapping(uint256 streamID => address user) private _streamIDOwners;
    mapping(address user => UserData) public userData;
    mapping(uint16 epoch => uint256) public rewardPerToken;
    uint256 public totalStaked;
    uint256 public totalVestedStaked;
    uint256 public newStaked;
    uint256 public newVestedStaked;
    uint256 public totalRewards;
    uint16 public currentEpoch;
    uint16 public lastEpochRewarded;
    mapping(address authorizedSablierSender => bool) public authorizedSablierSenders;
    uint256 public constant epochDuration = 86_400 * 7;
    uint8 public constant lockCycle = 6;
    uint256 public constant PRECISION_18 = 1e18;
    uint8 public constant claimCycle = 3;
    ERC20 public immutable fjordToken;
    uint256 public immutable startTime;
    address public rewardAdmin;
    constructor(
        address _fjordToken,
        address _rewardAdmin,
        address _sablier,
        address _authorizedSablierSender,
        address _fjordPoints
    ) {
        if (
            _rewardAdmin == address(0) || _sablier == address(0) || _fjordToken == address(0)
                || _fjordPoints == address(0)
        ) revert InvalidZeroAddress();
        startTime = block.timestamp;
        owner = msg.sender;
        fjordToken = ERC20(_fjordToken);
        currentEpoch = 1;
        rewardAdmin = _rewardAdmin;
        sablier = ISablierV2Lockup(_sablier);
        points = IFjordPoints(_fjordPoints);
        if (_authorizedSablierSender != address(0)) {
            authorizedSablierSenders[_authorizedSablierSender] = true;
        }
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert CallerDisallowed();
        _;
    }
    modifier onlyRewardAdmin() {
        if (msg.sender != rewardAdmin) revert CallerDisallowed();
        _;
    }
    modifier checkEpochRollover() {
        _checkEpochRollover();
        _;
    }
    modifier redeemPendingRewards() {
        _redeem(msg.sender);
        _;
    }
    modifier onlySablier() {
        if (msg.sender != address(sablier)) revert CallerDisallowed();
        _;
    }
    function getEpoch(uint256 _timestamp) public view returns (uint16) {
        if (_timestamp < startTime) return 0;
        return uint16((_timestamp - startTime) / epochDuration) + 1;
    }
    function getActiveDeposits(address _user) public view returns (uint256[] memory) {
        return _activeDeposits[_user].values();
    }
    function getStreamData(address _user, uint256 _streamID) public view returns (NFTData memory) {
        return _streamIDs[_user][_streamID];
    }
    function getStreamOwner(uint256 _streamID) public view returns (address) {
        return _streamIDOwners[_streamID];
    }
    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidZeroAddress();
        owner = _newOwner;
    }
    function setRewardAdmin(address _rewardAdmin) external onlyOwner {
        if (_rewardAdmin == address(0)) revert InvalidZeroAddress();
        rewardAdmin = _rewardAdmin;
    }
    function addAuthorizedSablierSender(address _address) external onlyOwner {
        authorizedSablierSenders[_address] = true;
    }
    function removeAuthorizedSablierSender(address _address) external onlyOwner {
        if (authorizedSablierSenders[_address]) authorizedSablierSenders[_address] = false;
    }
    function stake(uint256 _amount) external checkEpochRollover redeemPendingRewards {
        if (_amount == 0) revert InvalidAmount();
        userData[msg.sender].unredeemedEpoch = currentEpoch;
        DepositReceipt storage dr = deposits[msg.sender][currentEpoch];
        if (dr.epoch == 0) {
            dr.staked = _amount;
            dr.epoch = currentEpoch;
            _activeDeposits[msg.sender].add(currentEpoch);
        } else {
            dr.staked += _amount;
        }
        newStaked += _amount;
        fjordToken.safeTransferFrom(msg.sender, address(this), _amount);
        points.onStaked(msg.sender, _amount);
        emit Staked(msg.sender, currentEpoch, _amount);
    }
    function stakeVested(uint256 _streamID) external checkEpochRollover redeemPendingRewards {
        if (!sablier.isStream(_streamID)) revert NotAStream();
        if (sablier.isCold(_streamID)) revert NotAWarmStream();
        if (!authorizedSablierSenders[sablier.getSender(_streamID)]) {
            revert StreamNotSupported();
        }
        if (address(sablier.getAsset(_streamID)) != address(fjordToken)) revert InvalidAsset();
        uint128 depositedAmount = sablier.getDepositedAmount(_streamID);
        uint128 withdrawnAmount = sablier.getWithdrawnAmount(_streamID);
        uint128 refundedAmount = sablier.getRefundedAmount(_streamID);
        if (depositedAmount - (withdrawnAmount + refundedAmount) <= 0) revert InvalidAmount();
        uint256 _amount = depositedAmount - (withdrawnAmount + refundedAmount);
        userData[msg.sender].unredeemedEpoch = currentEpoch;
        DepositReceipt storage dr = deposits[msg.sender][currentEpoch];
        if (dr.epoch == 0) {
            dr.vestedStaked = _amount;
            dr.epoch = currentEpoch;
            _activeDeposits[msg.sender].add(currentEpoch);
        } else {
            dr.vestedStaked += _amount;
        }
        _streamIDs[msg.sender][_streamID] = NFTData({ epoch: currentEpoch, amount: _amount });
        _streamIDOwners[_streamID] = msg.sender;
        newStaked += _amount;
        newVestedStaked += _amount;
        sablier.transferFrom({ from: msg.sender, to: address(this), tokenId: _streamID });
        points.onStaked(msg.sender, _amount);
        emit VestedStaked(msg.sender, currentEpoch, _streamID, _amount);
    }
    function unstake(uint16 _epoch, uint256 _amount)
        external
        checkEpochRollover
        redeemPendingRewards
        returns (uint256 total)
    {
        if (_amount == 0) revert InvalidAmount();
        DepositReceipt storage dr = deposits[msg.sender][_epoch];
        if (dr.epoch == 0) revert DepositNotFound();
        if (dr.staked < _amount) revert UnstakeMoreThanDeposit();
        if (currentEpoch != _epoch) {
            if (currentEpoch - _epoch <= lockCycle) revert UnstakeEarly();
        }
        dr.staked -= _amount;
        if (currentEpoch != _epoch) {
            totalStaked -= _amount;
            userData[msg.sender].totalStaked -= _amount;
        } else {
            newStaked -= _amount;
        }
        if (dr.staked == 0 && dr.vestedStaked == 0) {
            if (userData[msg.sender].unredeemedEpoch == currentEpoch) {
                userData[msg.sender].unredeemedEpoch = 0;
            }
            delete deposits[msg.sender][_epoch];
            _activeDeposits[msg.sender].remove(_epoch);
        }
        total = _amount;
        fjordToken.safeTransfer(msg.sender, total);
        points.onUnstaked(msg.sender, _amount);
        emit Unstaked(msg.sender, _epoch, _amount);
    }
    function unstakeVested(uint256 _streamID) external checkEpochRollover redeemPendingRewards {
        NFTData memory data = _streamIDs[msg.sender][_streamID];
        DepositReceipt memory dr = deposits[msg.sender][data.epoch];
        if (data.epoch == 0 || data.amount == 0 || dr.vestedStaked == 0 || dr.epoch == 0) {
            revert DepositNotFound();
        }
        if (currentEpoch != data.epoch) {
            if (currentEpoch - data.epoch <= lockCycle) revert UnstakeEarly();
        }
        _unstakeVested(msg.sender, _streamID, data.amount);
    }
    function _unstakeVested(address streamOwner, uint256 _streamID, uint256 amount) internal {
        NFTData storage data = _streamIDs[streamOwner][_streamID];
        DepositReceipt storage dr = deposits[streamOwner][data.epoch];
        if (amount > data.amount) revert InvalidAmount();
        bool isFullUnstaked = data.amount == amount;
        uint16 epoch = data.epoch;
        dr.vestedStaked -= amount;
        if (currentEpoch != data.epoch) {
            totalStaked -= amount;
            totalVestedStaked -= amount;
            userData[streamOwner].totalStaked -= amount;
        } else {
            newStaked -= amount;
            newVestedStaked -= amount;
        }
        if (dr.vestedStaked == 0 && dr.staked == 0) {
            if (userData[streamOwner].unredeemedEpoch == currentEpoch) {
                userData[streamOwner].unredeemedEpoch = 0;
            }
            delete deposits[streamOwner][data.epoch];
            _activeDeposits[streamOwner].remove(data.epoch);
        }
        if (isFullUnstaked) {
            delete _streamIDs[streamOwner][_streamID];
            delete _streamIDOwners[_streamID];
        } else {
            data.amount -= amount;
        }
        if (isFullUnstaked) {
            sablier.transferFrom({ from: address(this), to: streamOwner, tokenId: _streamID });
        }
        points.onUnstaked(msg.sender, amount);
        emit VestedUnstaked(streamOwner, epoch, amount, _streamID);
    }
    function unstakeAll()
        external
        checkEpochRollover
        redeemPendingRewards
        returns (uint256 totalStakedAmount)
    {
        uint256[] memory activeDeposits = getActiveDeposits(msg.sender);
        if (activeDeposits.length == 0) revert NoActiveDeposit();
        for (uint16 i = 0; i < activeDeposits.length; i++) {
            uint16 epoch = uint16(activeDeposits[i]);
            DepositReceipt storage dr = deposits[msg.sender][epoch];
            if (dr.epoch == 0 || currentEpoch - epoch <= lockCycle) continue;
            totalStakedAmount += dr.staked;
            if (dr.vestedStaked == 0) {
                delete deposits[msg.sender][epoch];
                _activeDeposits[msg.sender].remove(epoch);
            } else {
                dr.staked = 0;
            }
        }
        totalStaked -= totalStakedAmount;
        userData[msg.sender].totalStaked -= totalStakedAmount;
        fjordToken.transfer(msg.sender, totalStakedAmount);
        points.onUnstaked(msg.sender, totalStakedAmount);
        emit UnstakedAll(
            msg.sender, totalStakedAmount, activeDeposits, getActiveDeposits(msg.sender)
        );
    }
    function claimReward(bool _isClaimEarly)
        external
        checkEpochRollover
        redeemPendingRewards
        returns (uint256 rewardAmount, uint256 penaltyAmount)
    {
        UserData storage ud = userData[msg.sender];
        if (
            claimReceipts[msg.sender].requestEpoch > 0
                || claimReceipts[msg.sender].requestEpoch >= currentEpoch - 1
        ) revert ClaimTooEarly();
        if (ud.unclaimedRewards == 0) revert NothingToClaim();
        if (!_isClaimEarly) {
            claimReceipts[msg.sender] =
                ClaimReceipt({ requestEpoch: currentEpoch, amount: ud.unclaimedRewards });
            emit ClaimReceiptCreated(msg.sender, currentEpoch);
            return (0, 0);
        }
        rewardAmount = ud.unclaimedRewards;
        penaltyAmount = rewardAmount / 2;
        rewardAmount -= penaltyAmount;
        if (rewardAmount == 0) return (0, 0);
        totalRewards -= (rewardAmount + penaltyAmount);
        userData[msg.sender].unclaimedRewards -= (rewardAmount + penaltyAmount);
        fjordToken.safeTransfer(msg.sender, rewardAmount);
        emit EarlyRewardClaimed(msg.sender, rewardAmount, penaltyAmount);
    }
    function completeClaimRequest()
        external
        checkEpochRollover
        redeemPendingRewards
        returns (uint256 rewardAmount)
    {
        ClaimReceipt memory cr = claimReceipts[msg.sender];
        if (cr.requestEpoch < 1) revert ClaimReceiptNotFound();
        if (currentEpoch - cr.requestEpoch <= claimCycle) revert CompleteRequestTooEarly();
        rewardAmount = cr.amount;
        userData[msg.sender].unclaimedRewards -= rewardAmount;
        totalRewards -= rewardAmount;
        delete claimReceipts[msg.sender];
        fjordToken.safeTransfer(msg.sender, rewardAmount);
        emit RewardClaimed(msg.sender, rewardAmount);
    }
    function _checkEpochRollover() internal {
        uint16 latestEpoch = getEpoch(block.timestamp);
        if (latestEpoch > currentEpoch) {
            currentEpoch = latestEpoch;
            if (totalStaked > 0) {
                uint256 currentBalance = fjordToken.balanceOf(address(this));
                uint256 pendingRewards = (currentBalance + totalVestedStaked + newVestedStaked)
                    - totalStaked - newStaked - totalRewards;
                uint256 pendingRewardsPerToken = (pendingRewards * PRECISION_18) / totalStaked;
                totalRewards += pendingRewards;
                for (uint16 i = lastEpochRewarded + 1; i < currentEpoch; i++) {
                    rewardPerToken[i] = rewardPerToken[lastEpochRewarded] + pendingRewardsPerToken;
                    emit RewardPerTokenChanged(i, rewardPerToken[i]);
                }
            } else {
                for (uint16 i = lastEpochRewarded + 1; i < currentEpoch; i++) {
                    rewardPerToken[i] = rewardPerToken[lastEpochRewarded];
                    emit RewardPerTokenChanged(i, rewardPerToken[i]);
                }
            }
            totalStaked += newStaked;
            totalVestedStaked += newVestedStaked;
            newStaked = 0;
            newVestedStaked = 0;
            lastEpochRewarded = currentEpoch - 1;
        }
    }
    function _redeem(address sender) internal {
        UserData storage ud = userData[sender];
        ud.unclaimedRewards +=
            calculateReward(ud.totalStaked, ud.lastClaimedEpoch, currentEpoch - 1);
        ud.lastClaimedEpoch = currentEpoch - 1;
        if (ud.unredeemedEpoch > 0 && ud.unredeemedEpoch < currentEpoch) {
            DepositReceipt memory deposit = deposits[sender][ud.unredeemedEpoch];
            ud.unclaimedRewards += calculateReward(
                deposit.staked + deposit.vestedStaked, ud.unredeemedEpoch, currentEpoch - 1
            );
            ud.unredeemedEpoch = 0;
            ud.totalStaked += (deposit.staked + deposit.vestedStaked);
        }
    }
    function addReward(uint256 _amount) external onlyRewardAdmin {
        if (_amount == 0) revert InvalidAmount();
        uint16 previousEpoch = currentEpoch;
        fjordToken.safeTransferFrom(msg.sender, address(this), _amount);
        _checkEpochRollover();
        emit RewardAdded(previousEpoch, msg.sender, _amount);
    }
    function calculateReward(uint256 _amount, uint16 _fromEpoch, uint16 _toEpoch)
        internal
        view
        returns (uint256 rewardAmount)
    {
        rewardAmount =
            (_amount * (rewardPerToken[_toEpoch] - rewardPerToken[_fromEpoch])) / PRECISION_18;
    }
    function onStreamWithdrawn(
        uint256, /*streamId*/
        address, /*caller*/
        address, /*to*/
        uint128 /*amount*/
    ) external override onlySablier {
    }
    function onStreamRenounced(uint256 /*streamId*/ ) external override onlySablier {
    }
    function onStreamCanceled(
        uint256 streamId,
        address sender,
        uint128 senderAmount,
        uint128 /*recipientAmount*/
    ) external override onlySablier checkEpochRollover {
        address streamOwner = _streamIDOwners[streamId];
        if (streamOwner == address(0)) revert StreamOwnerNotFound();
        _redeem(streamOwner);
        NFTData memory nftData = _streamIDs[streamOwner][streamId];
        uint256 amount =
            uint256(senderAmount) > nftData.amount ? nftData.amount : uint256(senderAmount);
        _unstakeVested(streamOwner, streamId, amount);
        emit SablierCanceled(streamOwner, streamId, sender, amount);
    }
}
