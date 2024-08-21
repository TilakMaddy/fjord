pragma solidity =0.8.21;
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20Burnable } from
    "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { SafeMath } from "lib/openzeppelin-contracts/contracts/utils/math/SafeMath.sol";
contract FjordAuction {
    using SafeMath for uint256;
    error InvalidFjordPointsAddress();
    error InvalidAuctionTokenAddress();
    error AuctionAlreadyEnded();
    error AuctionNotYetEnded();
    error AuctionEndAlreadyCalled();
    error NoTokensToClaim();
    error NoBidsToWithdraw();
    error InvalidUnbidAmount();
    ERC20Burnable public fjordPoints;
    IERC20 public auctionToken;
    address public owner;
    uint256 public auctionEndTime;
    uint256 public totalBids;
    uint256 public totalTokens;
    uint256 public multiplier;
    bool public ended;
    mapping(address => uint256) public bids;
    uint256 public constant PRECISION_18 = 1e18;
    event AuctionEnded(uint256 totalBids, uint256 totalTokens);
    event TokensClaimed(address indexed bidder, uint256 amount);
    event BidAdded(address indexed bidder, uint256 amount);
    event BidWithdrawn(address indexed bidder, uint256 amount);
    constructor(
        address _fjordPoints,
        address _auctionToken,
        uint256 _biddingTime,
        uint256 _totalTokens
    ) {
        if (_fjordPoints == address(0)) {
            revert InvalidFjordPointsAddress();
        }
        if (_auctionToken == address(0)) {
            revert InvalidAuctionTokenAddress();
        }
        fjordPoints = ERC20Burnable(_fjordPoints);
        auctionToken = IERC20(_auctionToken);
        owner = msg.sender;
        auctionEndTime = block.timestamp.add(_biddingTime);
        totalTokens = _totalTokens;
    }
    function bid(uint256 amount) external {
        if (block.timestamp > auctionEndTime) {
            revert AuctionAlreadyEnded();
        }
        bids[msg.sender] = bids[msg.sender].add(amount);
        totalBids = totalBids.add(amount);
        fjordPoints.transferFrom(msg.sender, address(this), amount);
        emit BidAdded(msg.sender, amount);
    }
    function unbid(uint256 amount) external {
        if (block.timestamp > auctionEndTime) {
            revert AuctionAlreadyEnded();
        }
        uint256 userBids = bids[msg.sender];
        if (userBids == 0) {
            revert NoBidsToWithdraw();
        }
        if (amount > userBids) {
            revert InvalidUnbidAmount();
        }
        bids[msg.sender] = bids[msg.sender].sub(amount);
        totalBids = totalBids.sub(amount);
        fjordPoints.transfer(msg.sender, amount);
        emit BidWithdrawn(msg.sender, amount);
    }
    function auctionEnd() external {
        if (block.timestamp < auctionEndTime) {
            revert AuctionNotYetEnded();
        }
        if (ended) {
            revert AuctionEndAlreadyCalled();
        }
        ended = true;
        emit AuctionEnded(totalBids, totalTokens);
        if (totalBids == 0) {
            auctionToken.transfer(owner, totalTokens);
            return;
        }
        multiplier = totalTokens.mul(PRECISION_18).div(totalBids);
        uint256 pointsToBurn = fjordPoints.balanceOf(address(this));
        fjordPoints.burn(pointsToBurn);
    }
    function claimTokens() external {
        if (!ended) {
            revert AuctionNotYetEnded();
        }
        uint256 userBids = bids[msg.sender];
        if (userBids == 0) {
            revert NoTokensToClaim();
        }
        uint256 claimable = userBids.mul(multiplier).div(PRECISION_18);
        bids[msg.sender] = 0;
        auctionToken.transfer(msg.sender, claimable);
        emit TokensClaimed(msg.sender, claimable);
    }
}
