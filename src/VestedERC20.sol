// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

import {IBarnraisePodline} from "./interfaces/IBarnraisePodline.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";

import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";

/// TODO This might not be needed if the Decimals work out in the calcs...
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";


/// @title Beanstalk VestedERC20
/// @author zrowgz
/// @author Modified from zefram.eth's VestedERC20 
/// https://github.com/ZeframLou/vested-erc20/blob/c937b59b14c602cf885b7e144f418a942ee5336b/src/VestedERC20.sol 
/// @notice An ERC20 token wrapper that linearly vests underlying token during 
/// the Beanstalk Farms Barnraise Podline payoff period.
contract VestedERC20 is ERC20 {

    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error unauthorized();
    error noPodlineLength();
    error alreadyInitialized();
    error insufficientFunds();
    error emergencyShutdown();


    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event PodlineSet(uint256 indexed podlineLength);

    event Redeemed(
        address indexed beneficiary, 
        uint256 underlyingAmount, 
        uint256 sharesRedeemed, 
        uint256 sharesForfeit
        );

    event Deposited(
        uint256 amountUnderlyingDeposited, 
        uint256 underlyingBalance, 
        uint256 BDV
        );

    event Shutdown(bool shutdown, bool release, uint timestamp);


    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice Immutable decimal precision
    uint256 immutable PRECISION = 1e18;

    // External Addresses
    /// @notice Address of the underlying asset (either BEAN or BEAN LP)
    IERC20 public immutable underlying; // address of underlying asset
    IBarnraisePodline public immutable barnraisePodline; // for accessing the current podline length
    address public immutable beanstalkProtocol; // for accessing the variables in beanstalk (may replace other addresses)

    /// @notice Owner address - BSF Multisig
    address public owner;
    /// @notice uint256 Stores forfeit balance
    uint256 public forfeitPool;
    /// @notice uint256 Stores initial length of barnraise podline
    uint256 public initalPodlineLength; // for preserving initial podline length for calcs

    /// @notice uint256 Stores balance of deposited underlying asset
    uint256 public underlyingBalance;
    /// @notice uint256 Stores the initial ratio of deposited underlying as BDV
    uint256 public ratioFactorOfBDV;
    /// @notice uint256 Stores the BDV of the underlying
    uint256 public BDV;

    /// @notice Emergency booleans for shutdown & release-vest
    bool public isShutdown; 
    bool public isForceVested;

    /// TODO - Variables to store call paths to correct locations in Beanstalk
    /// TODO - Set these prior to deployment or through constructor?
    /// TODO - Evaluate which of these will be needed. Depends upon the method of calling Beanstalk
    address vestingSilo; // used for minting directly to the vestingToken Silo @ beanstalk
    

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
        IBarnraisePodline _barnraisePodline,// TODO if separate from Beanstalk, use this!
        address _beanstalkProtocol, // TODO only needed if directly accessing the protocol!
        address _owner
        ) ERC20(
            _name,
            _symbol,
            _decimals
        ){
        owner = _owner;
        barnraisePodline = _barnraisePodline;
        beanstalkProtocol = _beanstalkProtocol;
        underlying = _underlying;
    }


    /// -----------------------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert unauthorized();
        }
        _;
    }


    /// -----------------------------------------------------------------------
    /// Owner actions
    /// -----------------------------------------------------------------------

    /// @notice Set initial length of the Barnraise Podline
    /// @notice Is immutable once set!
    /// @dev Must be ran after Barnraise has concluded
    function setInitalPodlineLength() external onlyOwner {

        if (initalPodlineLength != 0) {
            revert alreadyInitialized();
        }

        // Initialize the length of Barn Raise Podline
        initalPodlineLength = barnraisePodline.totalPods();

        emit PodlineSet(initalPodlineLength);
    }

    /// TODO Might not want to be able to set this manually if allowing for separate mint & deposit
    /// @notice Set the initial BDV per underlying
    function setRatioFactorBDV(uint256 _underlyingToBDV) external onlyOwner returns (uint256) {
        /// TODO Should this be immutable once deployed? 
        ///     If funds are recovered later, might be good to be able to adjust this?
        ratioFactorOfBDV = _underlyingToBDV;

        return (ratioFactorOfBDV);
    }

    /// @notice Mints supply without depositing underlying
    function mint(address _to, uint _shares) external onlyOwner {
        _mint(_to, _shares);
    }

    /// @notice Deposits underlying without minting shares
    /// @param _underlyingAmountDeposited The amount of underlying assets to deposit.
    /// @param _bdvOfDeposit The BDV of the entire amount of underlying being deposited.
    function depositUnderlying(
        uint256 _underlyingAmountDeposited,
        uint256 _bdvOfDeposit
        ) external onlyOwner {

            // To be able to deposit, Barnraise must have completed, therefore, check podlineLength.
            if (initalPodlineLength == 0) {
                revert noPodlineLength();
            }

            // Add the deposited underlying to balance of underlying
            underlyingBalance += _underlyingAmountDeposited;

            // Calculate BDV per share & store as the actualy `ratioFactorOfBDV`
            ratioFactorOfBDV = totalSupply / _bdvOfDeposit;

            //SolmateERC20 underlyingToken = SolmateERC20(underlying()); /// TODO How does this work?
            underlying.safeTransferFrom(
                msg.sender,
                address(this),
                _underlyingAmountDeposited
            );

            emit Deposited(underlyingBalance, _underlyingAmountDeposited, _bdvOfDeposit);
    }

    /// TODO This function is only needed IF tokens should be minted ONLY upon deposit of underlying.
    /// @notice Mints wrapped tokens using underlying tokens.
    /// @notice Only performed by BSF.
    /// @param _to Address to mint the shares to.
    /// @param _underlyingAmountDeposited The amount of underlying tokens to wrap.
    /// @return sharesToMint The amount of wrapped tokens minted.
    // function wrapAndMint(
    //     address _to, 
    //     uint256 _underlyingAmountDeposited
    //     ) external onlyOwner returns (uint256) {

    //         /// -------------------------------------------------------------------
    //         /// Validation
    //         /// -------------------------------------------------------------------

    //         if (initalPodlineLength == 0) {
    //             revert noPodlineLength();
    //         }

    //         /// -------------------------------------------------------------------
    //         /// State updates
    //         /// -------------------------------------------------------------------

    //         // Update the balance of underlying in contract
    //         underlyingBalance += _underlyingAmountDeposited;

    //         // Calculate the number of shares to mint
    //         uint256 sharesToMint = _underlyingAmountDeposited * ratioFactorOfBDV;

    //         _mint(_to, sharesToMint);

    //         /// -------------------------------------------------------------------
    //         /// Effects
    //         /// -------------------------------------------------------------------

    //         underlying.safeTransferFrom(
    //             msg.sender,
    //             address(this),
    //             _underlyingAmountDeposited
    //         );

    //     emit Deposited(underlyingBalance, _underlyingAmountDeposited, sharesToMint);
        
    //     return sharesToMint;
    // }

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
    /// @notice Recover all underlying assets to owner address
    /// @dev Does not burn any outstanding shares!
    function emergencyRecovery() external onlyOwner {

        // insert logic to transfer underlying to BSF
        underlying.safeTransfer(owner, underlyingBalance);
    }


    /// -----------------------------------------------------------------------
    /// User actions
    /// -----------------------------------------------------------------------

    /// TODO Create `convert` logic!

    /// TODO Is reentrancy guard needed? This does call out to obtain podlineLength... 
    /// @notice Allows a holder of the wrapped token to redeem the vested tokens
    /// @notice Acheives this by only accepting `amount`, using `msg.sender` for holder
    /// @param _shares The number of shares to be redeemed
    function redeem(uint256 _shares) external {
        if (isShutdown) {
            revert emergencyShutdown();
        }

        // Revert if attempting to redeem more than user's balance
        // Also revert if amount is greater than totalSupply
        if (_shares > balanceOf[msg.sender] || _shares > totalSupply) {
            revert insufficientFunds();
        }

        // Since the user has a balance, perform the function
        if (_shares <= balanceOf[msg.sender]) {

            // Only allow a user to redeem their own assets
            (
                uint256 withdrawableUnderlyingAmount, 
                uint256 sharesBeingRedeemed, 
                uint256 sharesForfeit
            ) = _previewRedeem(
                    _shares
                ); 

            /// -------------------------------------------------------------------
            /// State updates
            /// -------------------------------------------------------------------
/// TODO Ensure these decrements do not underflow!!! 
    /// Could happen if previous rounding caused changes in accounting
    /// See example in `redeemMax` for how this might fix it?
            // Decrease total supply
            _burn(msg.sender, _shares);
            //totalSupply -= _shares;

            // Decrease Underlying available.
            underlyingBalance -= withdrawableUnderlyingAmount;

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
            revert emergencyShutdown();
        }

        // Revert if attempting to redeem more than user's balance
        if (balanceOf[msg.sender] == 0) {
            revert insufficientFunds();
        }

        // Execute _previewRedeem & return the values
        (
            uint256 withdrawableUnderlyingAmount,  
            uint256 sharesBeingRedeemed,
            uint256 sharesForfeit
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

    /// @notice Check the current barnraiser podline length
    /// @return uint256 Number of pods awaiting payoff
    function _getPodlineLength() internal view returns (uint256) {
        return barnraisePodline.totalPods(); /// TODO Update this once known
    }

    /// TODO Updated this to be a percent rather than decimal 
    ///     correct the implementations of the values based on Beanstalk
    ///     Ensure that the values align as expected!
    /// @notice Calculates the payoff fraction
    /// @param _lineLength The current barnraiser podline length
    /// @return uint256 Percentage of pods remaining
    function _getPayoffFraction(uint256 _lineLength) internal view returns (uint256) {

        return (PRECISION - _lineLength * PRECISION / initalPodlineLength); ///TODO Handle these decimals
    }

    /// @notice Calculates amount of underlying user can redeem presently
    /// @param _shares Amount of vesting tokens to redeem for underlying
    /// @param _payoffFraction Percent of pods remaining
    /// @param lineLength Outstanding Barnraise Pods
    /// @return uint256 
    function _getRedeemableShares(
        uint256 _shares,
        uint256 _payoffFraction,
        uint256 lineLength
    ) internal pure returns (uint256) { 

        /// @notice If podline is not paid off yet, calculate the amount user can redeem
        if (lineLength > 0) {
            // Calculate the amount redeemable
            return (_payoffFraction * _shares / PRECISION); /// TODO Not a decimal fed in!
        }

        return (_shares);
    }

    /// TODO Could have the `lineLength` passed in from the calling function to save calls
    /// TODO Could pass in amountBeingRedeemed to allow a user to redeem portions
    /// TODO Could pass in `totalSupply` from the calling function
    /// @notice Calculates a user's share of the forfeit pool
    /// @param _sharesBeingRedeemed The amount of shares user can redeem
    function _getRedeemableUnderlying(
        uint256 _sharesBeingRedeemed
    ) internal view returns (uint256) {
         /// TODO Make sure that if redeeming the last shares, that it withdraws ALL underlying! 
        // if (_sharesBeingRedeemed == totalSupply) {
        //     return underlyingBalance;
        // }

        return underlyingBalance * (_sharesBeingRedeemed / totalSupply); /// TODO CHECK DECIMALS!!!
    }

    /// @notice Evaluate how much underlying is released for an amount of shares at this time.
    /// @param _shares Number of shares to redeem (in wei).
    /// @return uint256 Amount of underlying redeemable.
    /// @return uint256 Number of shares eligible for redemption.
    /// @return uint256 Number of shares forfeit.
    /// @dev Does not require an address, just the number of shares
    function _previewRedeem(
            uint256 _shares
        ) internal view returns (uint256, uint256, uint256) {      

            // Get current podlineLength
            uint256 lineLength = _getPodlineLength();
            // Calculate the fraction the podline has paid off
            uint256 payoffFraction = _getPayoffFraction(lineLength);
            // Calculate # of shares user can redeem for underlying
            uint256 sharesBeingRedeemed = _getRedeemableShares(_shares, payoffFraction, lineLength); /// TODO Fix calc - decimals!!
            // Caclulate # of underlying user will receive for # of shares eligible for redemption
            /// TODO should the getredeemableunderlying use shares or sharesbeingredeemed???
            uint256 withdrawableUnderlyingAmount = _getRedeemableUnderlying(sharesBeingRedeemed); /// TODO switch to shares mechanism
            // Calculate # of shares user forfeits
            uint256 sharesForfeit = _shares - sharesBeingRedeemed;

            return (withdrawableUnderlyingAmount, sharesBeingRedeemed, sharesForfeit);
        }


    /// -----------------------------------------------------------------------
    /// External Functions
    /// -----------------------------------------------------------------------

    /// @notice Computes the amount of vested tokens redeemable by an account
    /// @param _shares Amount of shares to redeem at this time
    /// @return uint256 Amount of underlying available to redeem shares for presently.
    /// @return uint256 Number of shares being redeemed.
    /// @return uint256 Number of shares being forfeit.
    function previewRedeem(
            uint256 _shares
        ) external view returns (uint256, uint256, uint256) {
            /// TODO Correct this so that it works for our use case
            /// TODO Requires an entire new function to calculate using an address param
            return _previewRedeem(_shares);
        }

    /// @notice Obtains current length of the Barn Raise Podline
    /// @return uint256 Current length of Barnraise Podline
    function getPodlineLength() external view returns (uint256) {
        return _getPodlineLength();
    }
}

    /**
    TODO:
    - Update variables based on Beanstalk addresses
    - Ensure ability to access either the Facet (see Note below) or the BR Podline
    - ENSURE CORRECT HANDLING OF MATH - DECIMAL ISSUE WITH PAYOFF FRACTION!!!
        - How many decimals to round to?
        - Could implement the imported library if concerns...
    
    Note
    - To access a facet:
    Source: https://github.com/bugout-dev/lootbox/blob/a317f451decbb6383abf79a1175639030837faf6/contracts/Lootbox.sol#L95
    ```
    address public terminusAddress; //just store the address
    TerminusFacet terminusContract = TerminusFacet(terminusAddress);
    terminusContract.mint(to, administratorPoolId, 1, "");
    ```

    Notes:
    - NOT adding `payable` to an address causes increased gas costs, wild!

    */

