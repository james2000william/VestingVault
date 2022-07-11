// SPDX-License-Identifier: MIT

pragma solidity 0.8.15;

import {IExternalContract} from "./interfaces/IExternalContract.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// TODO This might not be needed if the Decimals work out in the calcs...
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";


/// @title VestingVault
/// @author zrowgz
/// @author Modified from zefram.eth's VestedERC20 
/// https://github.com/ZeframLou/vested-erc20/blob/c937b59b14c602cf885b7e144f418a942ee5336b/src/VestedERC20.sol 
/// @notice An ERC20 token wrapper that linearly vests underlying token based on 
///         the values obtained from an external contract.
/// @notice Allows for a liquid vesting position that can be sold on a secondary market
///         while also allowing users to cash out at a linearly scaled fraction of their position.
    /**
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
    * It also takes into account whether there was a time frame for the fundraise or if duration is open-ended
        - Redemptions not allowed during the live raise if time-basead
    */

contract VestedERC20 is ERC20 {

    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error Unauthorized();
    error NoStartingValue();
    error AlreadyInitialized();
    error InsufficientFunds();
    error EmergencyShutdown();
    error AlreadyClaimed();
    error RaiseNotCompleted();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event VestParamSet(uint indexed goal, uint fundraiseEndTime, uint fundraiseStartTime);

    event Redeemed(
        address indexed beneficiary, 
        uint underlyingAmount, 
        uint sharesRedeemed, 
        uint sharesForfeit
        );

    event Deposited(
        uint amountUnderlyingDeposited, 
        uint underlyingBalance, 
        uint value
        );

    event Shutdown(bool shutdown, bool release, uint timestamp);

    event FundsRecovered(address token, uint amount);


    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice Immutable decimal precision
    uint immutable PRECISION = 1e18;

    // External Addresses
    /// @notice Address of the underlying asset
    IERC20 immutable underlying;
    /// @notice Interface to access the current vesting countdown value
    IExternalContract immutable vestor; 
    /// @notice Owner address
    address public owner;

    ////////// Local Storage Vars //////////
    /// @notice Stores initial value to countdown from for vesting (the goal)
    uint initialVestingValue;
    uint goalValue;
    uint fundraiseEndTime;
    uint fundraiseStartTime;
    /// @notice uint Stores balance of deposited underlying asset
    uint public underlyingBalance;
    /// @notice The value per underlying token deposited
    //          This isn't necessary unless needing a conversion of vesting value to another asset.
    uint public valueRatioToUnderlying;
    /// @notice uint Stores balance of underlying forfeit from early redemooors
    uint public forfeitPool;

    ////////// Emergency Checks //////////
    /// @notice Emergency booleans for shutdown & release-vest
    bool public isShutdown; 
    bool public isForceVested;
    

    /// -----------------------------------------------------------------------
    /// Initialization actions
    /// -----------------------------------------------------------------------

    /// @notice Initialize the contract with the owner address
    /// @param _name Name of the VestingToken
    /// @param _symbol Token symbol
    /// @param _decimals Token decimals
    /// @param _owner The Beanstalk Farms (BSF) Multisig address
    /// @param _underlying Address of underlying token to be deposited
    constructor(
        // Inherited contract constructor params
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        // This contract constructor params
        IERC20 _underlying,
        IExternalContract _vestor,
        address _owner
        ) ERC20(
            _name,
            _symbol,
            _decimals
        ){
        owner = _owner;
        vestor = _vestor;
        underlying = _underlying;
    }


    /// -----------------------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }


    /// -----------------------------------------------------------------------
    /// Owner actions
    /// -----------------------------------------------------------------------

    /// @notice Set initial length of the Barnraise Podline
    /// @notice Is immutable once set!
    /// @dev Must be ran after Barnraise has concluded
    function setVestingParams() external onlyOwner {

        ///////// Checks /////////
        if (initialVestingValue != 0) {
            revert AlreadyInitialized();
        }

        // Initialize the params from the external contract
        goalValue = vestor.getGoalValue();
        fundraiseEndTime = vestor.getEndTime();
        fundraiseStartTime = vestor.getStartTime();

        emit VestParamSet(goalValue, fundraiseEndTime, fundraiseStartTime);
    }

    /// @notice Mints supply without depositing underlying
    function mint(address _to, uint _shares) external onlyOwner {
        _mint(_to, _shares);
    }

    /// @notice Deposits underlying without minting shares
    /// @param _underlyingAmountDeposited The amount of underlying assets to deposit.
    /// @param _valueOfDeposit The BDV of the entire amount of underlying being deposited.
    /// @dev When the underlying get's deposited, it should not mint shares. Users can then claim their shares, 
    ///         which would check the balance of the fundraiser.
    ///         Allows for depositing without sending out vesting shares.
    function depositUnderlying(
        uint256 _underlyingAmountDeposited,
        uint256 _valueOfDeposit
        ) external onlyOwner {

            // To be able to deposit, must have a target value
            if (initialVestingValue == 0) {
                revert NoStartingValue();
            }

            // Add the deposited underlying to balance of underlying
            underlyingBalance += _underlyingAmountDeposited;

            // Calculate the value per share & store as the actualy `valueRatioToUnderlying`
            valueRatioToUnderlying = totalSupply / _valueOfDeposit;

            //SolmateERC20 underlyingToken = SolmateERC20(underlying()); 
            underlying.safeTransferFrom(
                msg.sender,
                address(this),
                _underlyingAmountDeposited
            );

            emit Deposited(underlyingBalance, _underlyingAmountDeposited, _valueOfDeposit);
    }

    /// TODO This function is only needed IF tokens should be minted ONLY upon deposit of underlying.
    /// @notice Mints wrapped tokens using underlying tokens.
    /// @notice Only performed by BSF.
    /// @param _to Address to mint the shares to.
    /// @param _underlyingAmountDeposited The amount of underlying tokens to wrap.
    /// @return sharesToMint The amount of wrapped tokens minted.
    function depositAndMint(
        address _to, 
        uint256 _underlyingAmountDeposited
        ) external onlyOwner returns (uint256) {

            /// -------------------------------------------------------------------
            /// Validation
            /// -------------------------------------------------------------------

            if (initialVestingValue == 0) {
                revert NoStartingValue();
            }

            /// -------------------------------------------------------------------
            /// State updates
            /// -------------------------------------------------------------------

            // Update the balance of underlying in contract
            underlyingBalance += _underlyingAmountDeposited;

            // Calculate the number of shares to mint
            uint256 sharesToMint = _underlyingAmountDeposited * valueRatioToUnderlying;

            _mint(_to, sharesToMint);

            /// -------------------------------------------------------------------
            /// Effects
            /// -------------------------------------------------------------------

            underlying.safeTransferFrom(
                msg.sender,
                address(this),
                _underlyingAmountDeposited
            );

        emit Deposited(underlyingBalance, _underlyingAmountDeposited, sharesToMint);
        
        return sharesToMint;
    }

    /// @notice Halts redemptions and/or vests all tokens completely.
    /// @notice Only callable by owner.
    /// @param _shutdown Boolean to shut down all functioning.
    /// @param _isForceVested Releases all vesting locks, allowing users to withdraw.
    /// @dev Probably best to only set one or the other of these to `true`.
    function setEmergencyShutdown(bool _shutdown, bool _isForceVested) external onlyOwner {

        // have the option to halt withdrawals temporarily and/or permanently
        isShutdown = _shutdown;

        // have the option to unlock all assets
        isForceVested = _isForceVested;

        emit Shutdown(isShutdown, isForceVested, block.timestamp);
    }

    /// TODO Implement this into the appropriate functions if desired
    ///      * Having this may not be desirable, as investors could be rugged!
    /// @notice Recover all underlying assets to owner address
    /// @dev Does not burn any outstanding shares!
    function emergencyRecovery(address _token) external onlyOwner {

        // Allows for withdrawal of any ERC20
        if (IERC20(_token) == underlying) {
            IERC20(_token).safeTransfer(owner, underlyingBalance);
        }
        else IERC20(_token).transfer(owner, IERC20(_token).balanceOf(address(this)));

        emit FundsRecovered(_token, IERC20(_token).balanceOf(address(this)));
    }


    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /// @notice Allow user to claim shares after contributing to fundraise by
    //          minting the shares for this vault based on raised funds & deposits.
    function claimShares() public {
        // User should have no balance
        if (balanceOf[msg.sender] != 0) {
            revert AlreadyClaimed();
        }
        if (fundraiseEndTime != 0) {
            if (fundraiseEndTime < block.timestamp) {
                revert RaiseNotCompleted();
            }
            /// Else, carry on since there's no defined end time of raise.
        }

        // Get user's balance of contributions
        uint userContributed = vestor.getUserContributions(msg.sender); /// TODO Check this balance getter

        // Get the total contributed amount
        uint totalContributions = vestor.getAmountRaised();

        // Mint it!
        _mint(msg.sender, ((userContributed / totalContributions) * underlyingBalance));
    }

    /// TODO Is reentrancy guard needed? This does call out to obtain podlineLength... 
    /// @notice Allows a holder of the wrapped token to redeem the vested tokens
    /// @notice Acheives this by only accepting `amount`, using `msg.sender` for holder
    /// @param _shares The number of shares to be redeemed
    function redeem(uint _shares) external {

            /// -------------------------------------------------------------------
            /// Checks
            /// -------------------------------------------------------------------
        if (isShutdown) {
            revert EmergencyShutdown();
        }
        if (fundraiseEndTime != 0) {
            if (fundraiseEndTime < block.timestamp) {
                revert RaiseNotCompleted();
            }
            /// Else, carry on since there's no defined end time of raise.
        }
        // Revert if attempting to redeem more than user's balance
        // Also revert if amount is greater than totalSupply
        if (_shares > balanceOf[msg.sender] || _shares > totalSupply) {
            revert InsufficientFunds();
        }

        // Since the user has a balance, perform the function
        if (_shares <= balanceOf[msg.sender]) {

            // Only allow a user to redeem their own assets
            (
                uint withdrawableUnderlyingAmount, 
                uint sharesBeingRedeemed, 
                uint sharesForfeit
            ) = _previewRedeem(
                    _shares
                ); 

            /// -------------------------------------------------------------------
            /// State updates
            /// -------------------------------------------------------------------

            // Decrease total supply
            _burn(msg.sender, _shares);

            // Decrease Underlying available.
            underlyingBalance -= withdrawableUnderlyingAmount;
            forfeitPool += sharesForfeit;

            /// -------------------------------------------------------------------
            /// Effects
            /// -------------------------------------------------------------------

            // Transfer the withdrawable amount to the user address
            underlying.safeTransfer(msg.sender, withdrawableUnderlyingAmount);

            emit Redeemed(msg.sender, withdrawableUnderlyingAmount, sharesBeingRedeemed, sharesForfeit);
        }
    }

    /// TODO Add reentrancy guard? 
    /// @notice Executes redemption of a user's entire balance.
    /// @notice No input parameters as it obtains these values through `msg.sender` & `balanceOf[msg.sender]`
    function redeemMax() external {
        if (isShutdown) {
            revert EmergencyShutdown();
        }

        // Revert if attempting to redeem more than user's balance
        if (balanceOf[msg.sender] == 0) {
            revert InsufficientFunds();
        }

        // Execute _previewRedeem & return the values
        (
            uint withdrawableUnderlyingAmount,  
            uint sharesBeingRedeemed,
            uint sharesForfeit
        ) = _previewRedeem(
                balanceOf[msg.sender]
            ); 

        /// -------------------------------------------------------------------
        /// State updates
        /// -------------------------------------------------------------------

/// TODO Ensure these decrements do not underflow!!! Could happen if previous rounding caused changes in accounting
        // like, if these are the last shares outstanding, then withdraw all underlying.
        // If these are the last redeemable shares:
        if (totalSupply - balanceOf[msg.sender] == 0) {
            withdrawableUnderlyingAmount = underlyingBalance;
            totalSupply = 0;
            underlyingBalance = 0;
        } /// TODO Or something like that...

        // If these aren't the last redeemable shares:
        if (totalSupply - balanceOf[msg.sender] > 0) {
            // Decrease total supply
            _burn(msg.sender, balanceOf[msg.sender]);
            
            // Decrease underlying balance
            underlyingBalance -= withdrawableUnderlyingAmount;
        }

        /// -------------------------------------------------------------------
        /// Effects
        /// -------------------------------------------------------------------

        // Transfer the withdrawable amount to the user address
        underlying.safeTransfer(msg.sender, withdrawableUnderlyingAmount);

        emit Redeemed(msg.sender, withdrawableUnderlyingAmount, sharesBeingRedeemed, sharesForfeit);
    }

    /// @notice Emergency user withdrawal of underlying
    function emergencyWithdrawalOfUnderlying() external {
        if (isForceVested) {

            // Redeem all underlying as user share percentage
            /// TODO Check DECIMALS!!! Depends on the values obtained from Beanstalk
            uint256 withdrawableUnderlyingAmount = (
                underlyingBalance * (
                    PRECISION * balanceOf[msg.sender] / totalSupply
                    ) / PRECISION);

            // Decrement the balance of the underlying
            underlyingBalance -= withdrawableUnderlyingAmount;

            underlying.safeTransfer(
                msg.sender, 
                withdrawableUnderlyingAmount
            );
        }
    }


    /// -----------------------------------------------------------------------
    /// Internal Functions
    /// -----------------------------------------------------------------------

    /// @notice Evaluate how much underlying is released for an amount of shares at this time.
    /// @param _shares Number of shares to redeem (in wei).
    /// @return uint Amount of underlying redeemable.
    /// @return uint Number of shares eligible for redemption.
    /// @return uint Number of shares forfeit.
    /// @dev Does not require an address, just the number of shares
    function _previewRedeem(
            uint _shares
        ) internal view returns (uint, uint, uint) {      

            // Get current amount raised
            uint amountRaised = _getCurrentAmountRaised();
            // Calculate the fraction the amount raised to goal
            uint percentOfGoal = _getFractionOfGoal(amountRaised);
            // Calculate # of shares user can redeem for underlying
            uint sharesBeingRedeemed = _getRedeemableShares(_shares, percentOfGoal, _amountToRaise); /// TODO Fix calc - decimals!!
            // Caclulate # of underlying user will receive for # of shares eligible for redemption
            /// TODO should the getredeemableunderlying use shares or sharesbeingredeemed???
            uint withdrawableUnderlyingAmount = _getRedeemableUnderlying(sharesBeingRedeemed); /// TODO switch to shares mechanism
            // Calculate # of shares user forfeits
            uint sharesForfeit = _shares - sharesBeingRedeemed;

            return (withdrawableUnderlyingAmount, sharesBeingRedeemed, sharesForfeit);
        }

    /// @notice Check the current barnraiser podline length
    /// @return uint Number of pods awaiting payoff
    function _getCurrentAmountRaised() internal view returns (uint) {
        return vestor.getAmountRaised(); 
    }

    /// TODO Updated this to be a percent rather than decimal 
    ///     correct the implementations of the values based on Beanstalk
    ///     Ensure that the values align as expected!
    /// @notice Calculates the payoff fraction
    /// @param _amountRaised The current barnraiser podline length
    /// @return uint Percentage of pods remaining
    function _getFractionOfGoal(uint _amountRaised) internal view returns (uint) {

        return (PRECISION - _amountRaised * PRECISION / initialVestingValue); ///TODO Handle these decimals
    }

    /// @notice Calculates amount of underlying user can redeem presently
    /// @param _shares Amount of vesting tokens to redeem for underlying
    /// @param _percentOfGoal Percent remaining to goal
    /// @param _amountToRaise Outstanding Barnraise Pods
    /// @return uint256 
    function _getRedeemableShares(
        uint _shares,
        uint _percentOfGoal,
        uint _amountToRaise
    ) internal pure returns (uint) { 

        /// @notice If podline is not paid off yet, calculate the amount user can redeem
        if (_amountToRaise > 0) {
            // Calculate the amount redeemable
            return (_percentOfGoal * _shares / PRECISION); /// TODO Not a decimal fed in!
        }

        return (_shares);
    }

    /// @notice Calculates a user's share of the forfeit pool
    /// @param _sharesBeingRedeemed The amount of shares user can redeem
    /// @return uint Return the user's current actual share of underlying.
    function _getRedeemableUnderlying(
        uint _sharesBeingRedeemed
    ) internal view returns (uint) {
         /// TODO Make sure that if redeeming the last shares, that it withdraws ALL underlying! 
        // if (_sharesBeingRedeemed == totalSupply) {
        //     return underlyingBalance;
        // }

        return underlyingBalance * (_sharesBeingRedeemed / totalSupply); /// TODO CHECK DECIMALS!!!
    }

    /// -----------------------------------------------------------------------
    /// External Functions
    /// -----------------------------------------------------------------------

    /// @notice Computes the amount of vested tokens redeemable by an account
    /// @param _shares Amount of shares to redeem at this time
    /// @return uint Amount of underlying available to redeem shares for presently.
    /// @return uint Number of shares being redeemed.
    /// @return uint Number of shares being forfeit.
    function previewRedeem(uint _shares) external view returns (uint, uint, uint) {
        /// TODO Requires an entire new function to calculate using an address param
        return _previewRedeem(_shares);
    }

    function previewUserRedeem(address _user) external view returns (uint, uint, uint) {
        return _previewRedeem(balanceOf[_user]); 
    }

    /// @notice Obtains current length of the Barn Raise Podline
    /// @return uint Current length of Barnraise Podline
    function getCurrentAmountRaised() external view returns (uint) {
        return _getCurrentAmountRaised();
    }
}