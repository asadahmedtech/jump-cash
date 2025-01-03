// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { IEntropyConsumer } from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import { IEntropy } from "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";

/**
 * @title Raffle
 * @notice A gas-optimized raffle contract with refund functionality and minimum ticket requirements
 */
contract Raffle is IEntropyConsumer, ReentrancyGuard, Ownable {
    // Add constructor to initialize Ownable
    constructor(address entropyAddress, address _feeCollector, uint256 _feePercentage) 
        Ownable(msg.sender) 
    {
        entropy = IEntropy(entropyAddress);
        feeCollector = _feeCollector;
        require(_feePercentage <= 1000, "Fee cannot exceed 10%"); // Max 10% fee
        feePercentage = _feePercentage;
    }

    // Custom errors for gas optimization
    error InvalidDistribution();
    error RaffleNotActive();
    error InsufficientTickets();
    error RaffleNotEnded();
    error RaffleAlreadyFinalized();
    error RaffleNotFinalized();
    error AlreadyClaimed();
    error TicketNotOwned();
    error TicketAlreadyRefunded();
    error RaffleIsNull();
    error InvalidTicketId();
    error ZeroAddress();

    struct TicketDistribution {
        uint96 fundPercentage; // Using uint96 to pack with ticketQuantity
        uint96 ticketQuantity;
    }

    struct RaffleInfo {
        address ticketToken;
        uint256 feeCollected;
        uint96 ticketTokenQuantity;
        uint32 endBlock;
        uint32 minTicketsRequired;
        uint32 totalSold;
        uint32 availableTickets;
        uint64 sequenceNumber;
        bool isActive;
        bool isFinalized;
        bool isNull;
        // Packed into single slots above
        mapping(address => uint256[]) userTickets;
        mapping(uint256 => address) ticketOwners;
        mapping(address => bool) hasClaimed;
        mapping(uint256 => bool) isTicketRefunded;
        TicketDistribution[] ticketDistribution;
        mapping(uint256 => uint256[]) winningTicketsPerPool;
    }

    // State variables
    mapping(uint256 => RaffleInfo) public raffles;
    mapping(uint256 => uint256) public sequenceNumberToRaffleId;
    uint256 public raffleCounter;
    IEntropy public entropy;
    uint256 public feePercentage; // In basis points (e.g., 250 = 2.50%)
    address public feeCollector;

    // Events
    event RaffleCreated(uint256 indexed raffleId, address creator, uint256 totalTickets);
    event TicketsPurchased(uint256 indexed raffleId, address indexed buyer, uint256 quantity);
    event TicketRefunded(uint256 indexed raffleId, address indexed user, uint256 ticketId);
    event SequenceNumberRequested(uint256 indexed raffleId, uint64 sequenceNumber);
    event RaffleFinalized(uint256 indexed raffleId, uint256 randomSeed);
    event RaffleDeclaredNull(uint256 indexed raffleId);
    event PrizeClaimed(uint256 indexed raffleId, address indexed winner, uint256 amount);
    event FeeCollected(uint256 indexed raffleId, uint256 amount);

    /**
     * @notice Creates a new raffle
     * @param totalTickets Total number of tickets available
     * @param ticketToken ERC20 token used for tickets
     * @param ticketTokenQuantity Cost per ticket in tokens
     * @param distribution Array of prize distributions
     * @param duration Duration in blocks
     * @param minTicketsRequired Minimum tickets that must be sold
     */
    function createRaffle(
        uint32 totalTickets,
        address ticketToken,
        uint96 ticketTokenQuantity,
        TicketDistribution[] calldata distribution,
        uint32 duration,
        uint32 minTicketsRequired
    ) external {
        if (ticketToken == address(0)) revert ZeroAddress();
        
        uint256 totalTicketsInDist;
        uint256 totalPercentage;
        
        for (uint256 i = 0; i < distribution.length;) {
            totalTicketsInDist += distribution[i].ticketQuantity;
            totalPercentage += distribution[i].fundPercentage;
            unchecked { ++i; }
        }
        
        if (totalTicketsInDist != totalTickets || totalPercentage != 100) {
            revert InvalidDistribution();
        }

        uint256 raffleId = ++raffleCounter;
        RaffleInfo storage raffle = raffles[raffleId];
        
        raffle.ticketToken = ticketToken;
        raffle.ticketTokenQuantity = ticketTokenQuantity;
        raffle.endBlock = uint32(block.number + duration);
        raffle.minTicketsRequired = minTicketsRequired;
        raffle.availableTickets = totalTickets;
        raffle.isActive = true;

        for (uint256 i = 0; i < distribution.length;) {
            raffle.ticketDistribution.push(distribution[i]);
            unchecked { ++i; }
        }

        emit RaffleCreated(raffleId, msg.sender, totalTickets);
    }

    /**
     * @notice Purchase tickets for a raffle
     * @param raffleId ID of the raffle
     * @param quantity Number of tickets to purchase
     */
    function buyTickets(uint256 raffleId, uint32 quantity) external nonReentrant {
        RaffleInfo storage raffle = raffles[raffleId];
        
        if (!raffle.isActive || block.number >= raffle.endBlock) revert RaffleNotActive();
        if (raffle.availableTickets < quantity) revert InsufficientTickets();
        if (quantity == 0) revert InvalidTicketId();

        // Safe multiplication check
        uint256 ticketCost = raffle.ticketTokenQuantity;
        if (ticketCost > type(uint256).max / quantity) revert("Arithmetic overflow");
        uint256 totalCost = quantity * ticketCost;
        
        // Transfer tokens first to prevent reentrancy
        IERC20(raffle.ticketToken).transferFrom(msg.sender, address(this), totalCost);

        uint32 ticketsAssigned;
        uint256 i;
        
        // Find available tickets (including refunded ones)
        while (ticketsAssigned < quantity && i < type(uint32).max) {
            if (raffle.ticketOwners[i] == address(0) || raffle.isTicketRefunded[i]) {
                raffle.ticketOwners[i] = msg.sender;
                raffle.userTickets[msg.sender].push(i);
                raffle.isTicketRefunded[i] = false;
                ticketsAssigned++;
            }
            i++;
        }
        
        // Check if we assigned all tickets
        if (ticketsAssigned != quantity) revert("Failed to assign all tickets");
        
        // Safe arithmetic operations
        if (raffle.availableTickets < quantity) revert InsufficientTickets();
        raffle.availableTickets -= quantity;
        
        uint32 newTotalSold = raffle.totalSold + quantity;
        if (newTotalSold < raffle.totalSold) revert("Overflow in totalSold");
        raffle.totalSold = newTotalSold;
        
        emit TicketsPurchased(raffleId, msg.sender, quantity);
    }

    /**
     * @notice Refund a specific ticket
     * @param raffleId ID of the raffle
     * @param ticketId ID of the ticket to refund
     */
    function refundTicket(uint256 raffleId, uint256 ticketId) external nonReentrant {
        RaffleInfo storage raffle = raffles[raffleId];
        
        if (!raffle.isActive && !raffle.isNull) revert RaffleNotActive();
        if (raffle.ticketOwners[ticketId] != msg.sender) revert TicketNotOwned();
        if (raffle.isTicketRefunded[ticketId]) revert TicketAlreadyRefunded();

        raffle.isTicketRefunded[ticketId] = true;
        unchecked {
            raffle.availableTickets++;
            raffle.totalSold--;
        }

        IERC20(raffle.ticketToken).transfer(msg.sender, raffle.ticketTokenQuantity);
        emit TicketRefunded(raffleId, msg.sender, ticketId);
    }

    /**
     * @notice Finalize the raffle and determine winners
     * @param raffleId ID of the raffle
     */
    function finalizeRaffle(uint256 raffleId) external payable {
        RaffleInfo storage raffle = raffles[raffleId];
        
        if (block.number < raffle.endBlock) revert RaffleNotEnded();
        if (raffle.isFinalized) revert RaffleAlreadyFinalized();

        if (raffle.totalSold < raffle.minTicketsRequired) {
            raffle.isNull = true;
            raffle.isActive = false;
            raffle.isFinalized = true;
            emit RaffleDeclaredNull(raffleId);
            return;
        }

        // Calculate and transfer fees
        uint256 totalPoolAmount = uint256(raffle.totalSold) * raffle.ticketTokenQuantity;
        uint256 feeAmount = (totalPoolAmount * feePercentage) / 10000;
        
        if (feeAmount > 0) {
            IERC20(raffle.ticketToken).transfer(feeCollector, feeAmount);
            raffle.feeCollected = feeAmount; // Store fee amount for reference
        }

        // Request random number
        address entropyProvider = entropy.getDefaultProvider();
        uint256 fee = entropy.getFee(entropyProvider);
 
        uint64 sequenceNumber = entropy.requestWithCallback{ value: fee }(
            entropyProvider,
            keccak256(abi.encodePacked(blockhash(block.number - 1), block.timestamp))
        );

        raffle.sequenceNumber = sequenceNumber;
        sequenceNumberToRaffleId[sequenceNumber] = raffleId;

        raffle.isActive = false;
        emit SequenceNumberRequested(raffleId, sequenceNumber);
    }

    /** 
     * @param sequenceNumber The sequence number of the request.
     * @param provider The address of the provider that generated the random number. If your app uses multiple providers, you can use this argument to distinguish which one is calling the app back.
     * @param randomNumber The generated random number.
     **/
    function entropyCallback(
        uint64 sequenceNumber,
        address provider,
        bytes32 randomNumber
    ) internal override {
        uint256 raffleId = sequenceNumberToRaffleId[sequenceNumber];
        RaffleInfo storage raffle = raffles[raffleId];

        uint256 randomSeed = uint256(randomNumber);
        _selectWinners(raffleId, randomSeed);
        
        raffle.isFinalized = true;

        emit RaffleFinalized(raffleId, randomSeed);
    }
    
    /**
     * @notice Internal function to select winners
     * @param raffleId ID of the raffle
     * @param randomSeed Random seed for winner selection
     */
    function _selectWinners(uint256 raffleId, uint256 randomSeed) internal {
        RaffleInfo storage raffle = raffles[raffleId];
        
        // Create array of valid tickets
        uint256[] memory availableTickets = new uint256[](raffle.totalSold);
        uint256 availableIndex;
        
        // Create array of valid tickets
        for (uint256 i = 0; i < type(uint32).max;) {
            if (raffle.ticketOwners[i] != address(0) && !raffle.isTicketRefunded[i]) {
                availableTickets[availableIndex] = i;
                unchecked { ++availableIndex; }
                if (availableIndex == raffle.totalSold) break;
            }
            unchecked { ++i; }
        }

        // Select winners for each pool
        uint256 currentSeed = randomSeed;
        uint256 processedTickets;

        for (uint256 i = 0; i < raffle.ticketDistribution.length;) {
            uint256 winnersCount = raffle.ticketDistribution[i].ticketQuantity;
            
            // Skip if no winners in this pool or no percentage allocated
            if (winnersCount == 0 || raffle.ticketDistribution[i].fundPercentage == 0) {
                unchecked { ++i; }
                continue;
            }

            // Make sure we don't try to select more winners than available tickets
            uint256 remainingTickets = raffle.totalSold - processedTickets;
            if (remainingTickets == 0) break;
            
            // Adjust winners count if needed
            winnersCount = winnersCount > remainingTickets ? remainingTickets : winnersCount;

            for (uint256 j = 0; j < winnersCount;) {
                currentSeed = uint256(keccak256(abi.encodePacked(currentSeed, j)));
                uint256 winnerIndex = processedTickets + (currentSeed % (raffle.totalSold - processedTickets));
                
                // Swap and select winner
                uint256 temp = availableTickets[processedTickets];
                availableTickets[processedTickets] = availableTickets[winnerIndex];
                availableTickets[winnerIndex] = temp;
                
                raffle.winningTicketsPerPool[i].push(availableTickets[processedTickets]);
                
                unchecked { 
                    ++processedTickets;
                    ++j;
                }
            }
            unchecked { ++i; }
        }
    }

    /**
     * @notice Claim prizes for winning tickets
     * @param raffleId ID of the raffle
     */
    function claimPrize(uint256 raffleId) external nonReentrant {
        RaffleInfo storage raffle = raffles[raffleId];
        
        if (!raffle.isFinalized) revert RaffleNotFinalized();
        if (raffle.isNull) revert RaffleIsNull();
        if (raffle.hasClaimed[msg.sender]) revert AlreadyClaimed();

        uint256[] memory userTicketIds = raffle.userTickets[msg.sender];
        if (userTicketIds.length == 0) return;

        uint256 totalPrize;
        // Calculate total pool minus fees
        uint256 totalPoolFunds = (uint256(raffle.totalSold) * raffle.ticketTokenQuantity) - raffle.feeCollected;

        for (uint256 i = 0; i < userTicketIds.length;) {
            uint256 ticketId = userTicketIds[i];
            
            for (uint256 j = 0; j < raffle.ticketDistribution.length;) {
                if (raffle.ticketDistribution[j].fundPercentage > 0) {
                    if (_isTicketInArray(ticketId, raffle.winningTicketsPerPool[j])) {
                        uint256 poolPrize = (totalPoolFunds * raffle.ticketDistribution[j].fundPercentage) / 100;
                        uint256 prizePerTicket = poolPrize / raffle.ticketDistribution[j].ticketQuantity;
                        totalPrize += prizePerTicket;
                        break;
                    }
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }

        if (totalPrize > 0) {
            raffle.hasClaimed[msg.sender] = true;
            IERC20(raffle.ticketToken).transfer(msg.sender, totalPrize);
            emit PrizeClaimed(raffleId, msg.sender, totalPrize);
        }
    }

    /**
     * @notice Claim refund for null raffle
     * @param raffleId ID of the raffle
     */
    function claimRefund(uint256 raffleId) external nonReentrant {
        RaffleInfo storage raffle = raffles[raffleId];
        
        if (!raffle.isNull) revert RaffleIsNull();
        if (raffle.hasClaimed[msg.sender]) revert AlreadyClaimed();

        uint256[] memory userTicketIds = raffle.userTickets[msg.sender];
        if (userTicketIds.length == 0) return;

        uint256 refundAmount;
        for (uint256 i = 0; i < userTicketIds.length;) {
            if (!raffle.isTicketRefunded[userTicketIds[i]]) {
                refundAmount += raffle.ticketTokenQuantity;
                raffle.isTicketRefunded[userTicketIds[i]] = true;
            }
            unchecked { ++i; }
        }

        if (refundAmount > 0) {
            raffle.hasClaimed[msg.sender] = true;
            IERC20(raffle.ticketToken).transfer(msg.sender, refundAmount);
        }
    }

    /**
     * @notice Check if a ticket is in an array
     * @param ticket Ticket ID to check
     * @param array Array of ticket IDs
     */
    function _isTicketInArray(uint256 ticket, uint256[] storage array) internal view returns (bool) {
        for (uint256 i = 0; i < array.length;) {
            if (array[i] == ticket) return true;
            unchecked { ++i; }
        }
        return false;
    }

    // View functions
    function getUserTickets(uint256 raffleId, address user) external view returns (uint256[] memory) {
        return raffles[raffleId].userTickets[user];
    }

    function getWinningTicketsForPool(uint256 raffleId, uint256 poolIndex) external view returns (uint256[] memory) {
        return raffles[raffleId].winningTicketsPerPool[poolIndex];
    }

    function getRaffleInfo(uint256 raffleId) external view returns (
        address ticketToken,
        uint96 ticketTokenQuantity,
        uint32 endBlock,
        uint32 minTicketsRequired,
        uint32 totalSold,
        uint32 availableTickets,
        bool isActive,
        bool isFinalized,
        bool isNull
    ) {
        RaffleInfo storage raffle = raffles[raffleId];
        return (
            raffle.ticketToken,
            raffle.ticketTokenQuantity,
            raffle.endBlock,
            raffle.minTicketsRequired,
            raffle.totalSold,
            raffle.availableTickets,
            raffle.isActive,
            raffle.isFinalized,
            raffle.isNull
        );
    }

    // Add fee management functions
    function setFeeCollector(address _feeCollector) external onlyOwner {
        if (_feeCollector == address(0)) revert ZeroAddress();
        feeCollector = _feeCollector;
    }

    function setFeePercentage(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= 1000, "Fee cannot exceed 10%");
        feePercentage = _feePercentage;
    }

    // getters
    function getFeeCollector() external view returns (address) {
        return feeCollector;
    }

    function getFeePercentage() external view returns (uint256) {
        return feePercentage;
    }

    function getSequenceFees() external view returns (uint256) {
        return entropy.getFee(entropy.getDefaultProvider());
    }

    // This method is required by the IEntropyConsumer interface.
    // It returns the address of the entropy contract which will call the callback.
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }
    
}
