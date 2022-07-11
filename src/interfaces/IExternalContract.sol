// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

interface IExternalContract {
    /**
    * @notice Interface for the example contract below.
    */
    function getGoalValue() external view returns (uint);
    function getAmountRaised() external view returns (uint);
    function getRemainingValue() external view returns (uint);
    function getStartTime() external view returns (uint);
    function getEndTime() external view returns (uint);
    function getUserContributions(address) external view returns (uint);
}


contract ExampleFundraiserContract {
    /**
    * @notice A basic example external contract that could be used with the VestingVault.
    *
    * There should be a value that is reducing over time that allows for the vesting 
    *   process to progress. This can be either a countdown or a count up.
    *   For examples,
    *   - There could be a time based count to a specific block or timestamp, where the
          difference between current block/time is shrinking as it approaches.  So, having
          a start value and end value & returning the current value
        - Token emissions based, like maxSupply - totalSupply
        - User engagement parameters (although this might add extra gas for specific functions)
            * Have a goal TVL & check against a snapshot from previous block (to prevent flash loan gaming)
            * Check a specific function call counter or unique addresses against goal values (gameable)
            * Fundraising goal versus amount currently raised
        - This could also be used to hit team goals for unlocking vests:
            * If attempting to accumulate a specific token, the goal number when team has succeeded
    * This allows for redeeming at any point, but the farther along to reaching the goal, the more
        underlying is vested and released.
        - If redeeming early, the forfeit tokens remain in the pool and are redistributed to remaining users
    */

    ////////// Errors //////////

    error MustContributeMoreThanZero();
    error FundraiseFull(uint);
    error RaiseTimeout(uint, uint);


    ////////// Events //////////

    event ContributionReceived(address indexed contributor, uint indexed value);


    ////////// Variables //////////

    /// @notice The start time for the raise.
    uint immutable startTime;
    /// @notice The end time of the raise.
    uint immutable endTime;
    /// @notice The goal value (in wei) to raise.
    uint immutable goalValue;
    /// @notice The current total amount raised.
    uint amountRaised;
    /// @notice The amount a given address has contributed.
    mapping(address => uint) public userContributions;


    ////////// Initialization //////////

    /// @notice Initialize the contract with the fundraising goal set.
    /// @param _fundraiseGoal Amount of eth in wei to raise.
    /// @param _startTime The time, in unix timestamp, when raise goes live.
    /// @param _duration In seconds, for the duration of the raise to run.
    constructor(
        uint _fundraiseGoal,
        uint _startTime, 
        uint _duration
    ) {
        goalValue = _fundraiseGoal;
        startTime = _startTime;
        endTime = startTime + _duration;
    }


    ////////// User Functions //////////

    /// @notice Contribute ether (in wei) to the fundraiser.
    /// @notice Increments the raised balance & address contribution balance by msg.value.
    /// @dev Accepts eth as msg.value to be transferred with txn.
    function contributeToFundraise() public payable {
        if (msg.value == 0) { 
            revert MustContributeMoreThanZero(); 
        }
        if (amountRaised >= goalValue) {
            revert FundraiseFull(amountRaised);
        }
        if (startTime > block.timestamp || endTime <= block.timestamp) {
            revert RaiseTimeout(startTime, endTime);
        }

        amountRaised += msg.value;
        userContributions[msg.sender] += msg.value;

        emit ContributionReceived(msg.sender, msg.value);
    }


    ////////// Getter Functions //////////
    
    /// @notice Retrieve the fundraiser goal value.
    /// @return uint goalValue
    function getGoalValue() external view returns (uint) {
        return goalValue;
    }

    /// @notice Retrieve the amount raised.
    /// @return uint amountRaised
    function getAmountRaised() external view returns (uint) {
        return amountRaised;
    }

    /// @notice Calculates how much remains to be raised to meet goal.
    /// @return uint goalValue - amountRaised
    function getRemainingValue() external view returns (uint) {
        if (goalValue == amountRaised) {
            return 0;
        }
        return goalValue - amountRaised;
    }

    /// @notice Retrieve the start time of raise.
    /// @return uint startTime in seconds.
    function getStartTime() external view returns (uint) {
        return startTime;
    }

    /// @notice Retreive the end time of raise.
    /// @return uint endTime in seconds.
    function getEndTime() external view returns (uint) {
        return endTime;
    }

    function getUserContributions(address _user) external view returns (uint) {
        return userContributions[_user];
    }
}