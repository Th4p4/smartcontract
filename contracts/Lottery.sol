// SPDX-License-Identifier: MIT

/*    ------------ External Imports ------------    */
import "@openzeppelin/contracts/utils/Strings.sol";
import "./RandomNumberConsumer.sol";

pragma solidity 0.8.14;

contract Lottery {
    uint256 public lotteryCount = 0;

    struct LotteryData {
        address lotteryOperator;
        uint256 ticketPrice;
        uint256 maxTickets;
        uint256 operatorCommissionPercentage;
        uint256 expiration;
        address lotteryWinner;
        address[] tickets;
        uint256 requestId;
    }

    struct LotteryStatus {
        uint256 lotteryId;
        bool fulfilled;
        bool exists;
        uint256[] randomNumber;
    }

    mapping(uint256 => LotteryData) public lottery;
    mapping(uint256 => LotteryStatus) public requests;

    RandomNumberConsumer public randomNumContract;

    /*    ------------ Constructor ------------    */

    constructor(address vrfV2Consumer) {
        randomNumContract = RandomNumberConsumer(vrfV2Consumer);
    }

    /*    ------------ Events ------------    */

    event LotteryCreated(
        address lotteryOperator,
        uint256 ticketPrice,
        uint256 maxTickets,
        uint256 operatorCommissionPercentage,
        uint256 expiration
    );

    event LogTicketCommission(
        uint256 lotteryId,
        address lotteryOperator,
        uint256 amount
    );

    event TicketsBought(
        address buyer,
        uint256 lotteryId,
        uint256 ticketsBought
    );

    event LotteryWinnerRequestSent(
        uint256 lotteryId,
        uint256 requestId,
        uint32 numWords
    );

    event LotteryWinnerDrawn(uint256 lotteryId, address lotteryWinner);

    event LotteryClaimed(
        uint256 lotteryId,
        address lotteryWinner,
        uint256 amount
    );

    /*    ------------ Modifiers ------------    */

    modifier onlyOperator(uint256 _lotteryId) {
        require(
            (msg.sender == lottery[_lotteryId].lotteryOperator),
            "Error: Caller is not the lottery operator"
        );
        _;
    }

    modifier canClaimLottery(uint256 _lotteryId) {
        require(
            (lottery[_lotteryId].lotteryWinner != address(0x0)),
            "Error: Lottery Winner not yet drawn"
        );
        require(
            (msg.sender == lottery[_lotteryId].lotteryWinner ||
                msg.sender == lottery[_lotteryId].lotteryOperator),
            "Error: Caller is not the lottery winner"
        );
        _;
    }

    /*    ------------ Read Functions ------------    */

    function getRemainingTickets(
        uint256 _lotteryId
    ) public view returns (uint256) {
        return
            lottery[_lotteryId].maxTickets - lottery[_lotteryId].tickets.length;
    }

    /*    ------------ Write Functions ------------    */

    function createLottery(
        address _lotteryOperator,
        uint256 _ticketPrice,
        uint256 _maxTickets,
        uint256 _operatorCommissionPercentage,
        uint256 _expiration
    ) public {
        require(
            _lotteryOperator != address(0),
            "Error: Lottery operator cannot be 0x0"
        );
        require(
            (_operatorCommissionPercentage >= 0 &&
                _operatorCommissionPercentage % 5 == 0),
            "Error: Commission percentage should be greater than zero and multiple of 5"
        );
        require(
            _expiration > block.timestamp,
            "Error: Expiration must be greater than current block timestamp"
        );
        require(_maxTickets > 0, "Error: Max tickets must be greater than 0");
        require(_ticketPrice > 0, "Error: Ticket price must be greater than 0");
        address[] memory ticketsArray;
        lotteryCount++;
        lottery[lotteryCount] = LotteryData({
            lotteryOperator: _lotteryOperator,
            ticketPrice: _ticketPrice,
            maxTickets: _maxTickets,
            operatorCommissionPercentage: _operatorCommissionPercentage,
            expiration: _expiration,
            lotteryWinner: address(0),
            tickets: ticketsArray,
            requestId: 0
        });
        emit LotteryCreated(
            _lotteryOperator,
            _ticketPrice,
            _maxTickets,
            _operatorCommissionPercentage,
            _expiration
        );
    }

    function BuyTickets(uint256 _lotteryId, uint256 _tickets) public payable {
        uint256 amount = msg.value;
        require(
            _tickets > 0,
            "Error: Number of tickets must be greater than 0"
        );
        require(
            _tickets <= getRemainingTickets(_lotteryId),
            "Error: Number of tickets must be less than or equal to remaining tickets"
        );
        require(
            amount >= _tickets * lottery[_lotteryId].ticketPrice,
            "Error: Ether value must be equal to number of tickets times ticket price"
        );
        require(
            block.timestamp < lottery[_lotteryId].expiration,
            "Error: Lottery has expired"
        );

        LotteryData storage currentLottery = lottery[_lotteryId];

        for (uint256 i = 0; i < _tickets; i++) {
            currentLottery.tickets.push(msg.sender);
        }

        emit TicketsBought(msg.sender, _lotteryId, _tickets);
    }

    function RequestLotteryWinner(
        uint256 _lotteryId
    ) external onlyOperator(_lotteryId) returns (uint256 requestId) {
        require(
            block.timestamp > lottery[_lotteryId].expiration,
            "Error: Lottery has not yet expired"
        );
        require(
            lottery[_lotteryId].lotteryWinner == address(0),
            "Error: Lottery winner already drawn"
        );
        requestId = randomNumContract.requestRandomWords();
        LotteryData storage currentLottery = lottery[_lotteryId];
        currentLottery.requestId = requestId;
        emit LotteryWinnerRequestSent(_lotteryId, requestId, 1);
        return requestId;
    }

    function PickWinner(uint256 _lotteryId) external onlyOperator(_lotteryId) {
        require(
            block.timestamp > lottery[_lotteryId].expiration,
            "Error: Lottery has not yet expired"
        );
        require(
            lottery[_lotteryId].lotteryWinner == address(0),
            "Error: Lottery winner already drawn"
        );
        (bool _fulfilled, uint256[] memory _randomWords) = randomNumContract
            .getRequestStatus(lottery[_lotteryId].requestId);
        require(
            _fulfilled,
            "Winner selection for this lottery id is still in progress."
        );
        uint256 winnerIndex = _randomWords[0] %
            lottery[_lotteryId].tickets.length;
        lottery[_lotteryId].lotteryWinner = lottery[_lotteryId].tickets[
            winnerIndex
        ];

        emit LotteryWinnerDrawn(
            _lotteryId,
            lottery[_lotteryId].tickets[winnerIndex]
        );
    }

    function ClaimLottery(
        uint256 _lotteryId
    ) public canClaimLottery(_lotteryId) {
        LotteryData storage currentLottery = lottery[_lotteryId];
        uint256 vaultAmount = currentLottery.tickets.length *
            currentLottery.ticketPrice;

        uint256 operatorCommission = vaultAmount /
            (100 / currentLottery.operatorCommissionPercentage);

        (bool sentCommission, ) = payable(currentLottery.lotteryOperator).call{
            value: operatorCommission
        }("");
        require(sentCommission);
        emit LogTicketCommission(
            _lotteryId,
            currentLottery.lotteryOperator,
            operatorCommission
        );

        uint256 winnerAmount = vaultAmount - operatorCommission;

        (bool sentWinner, ) = payable(currentLottery.lotteryWinner).call{
            value: winnerAmount
        }("");
        require(sentWinner);
        emit LotteryClaimed(
            _lotteryId,
            currentLottery.lotteryWinner,
            winnerAmount
        );
    }
}
