pragma solidity =0.8.21;
import "./FjordAuction.sol";
import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
contract AuctionFactory {
    address public fjordPoints;
    address public owner;
    event AuctionCreated(address indexed auctionAddress);
    error NotOwner();
    error InvalidAddress();
    constructor(address _fjordPoints) {
        if (_fjordPoints == address(0)) revert InvalidAddress();
        fjordPoints = _fjordPoints;
        owner = msg.sender;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }
    function setOwner(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidAddress();
        owner = _newOwner;
    }
    function createAuction(
        address auctionToken,
        uint256 biddingTime,
        uint256 totalTokens,
        bytes32 salt
    ) external onlyOwner {
        address auctionAddress = address(
            new FjordAuction{ salt: salt }(fjordPoints, auctionToken, biddingTime, totalTokens)
        );
        IERC20(auctionToken).transferFrom(msg.sender, auctionAddress, totalTokens);
        emit AuctionCreated(auctionAddress);
    }
}
