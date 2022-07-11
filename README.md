# WIP!!
# Parameter Based ERC20 Vesting Vault

---

## Use Cases
An ERC20 token wrapper that linearly vests underlying token based on the values obtained from an external contract.  
  
Allows for a liquid vesting position that can be sold on a secondary market while also allowing users to cash out at a linearly scaled fraction of their position.  

* There should be a value that is reducing over time that allows for the vesting: 
    *   process to progress. This can be either a countdown or a count up.
    *   For examples,
        -  There could be a time based count to a specific block or timestamp, where the difference between  current block/time is shrinking as it approaches.  So, having a start value and end value & returning the current value:  
        - Token emissions based, like maxSupply - totalSupply
        - User engagement parameters (although this might add extra gas for specific functions)
            * Have a goal TVL & check against a snapshot from previous block (to prevent flash loan gaming)
            * Check a specific function call counter or unique addresses against goal values (gameable)
            * Fundraising goal versus amount currently raised
        - This could also be used to hit team goals for unlocking vests:
            * If attempting to accumulate a specific token, the goal number when team has succeeded
* This allows for redeeming at any point, but the farther along to reaching the goal, the more underlying is vested and released.
    - If redeeming early, the forfeit tokens remain in the pool and are redistributed to remaining users
* It also takes into account whether there was a time frame for the fundraise or if duration is open-ended
    - Redemptions not allowed during the live raise if time-basead

---

## Requirements 
- Foundry 
 
## Installation
- Clone repository
- Create the `IExternalInterface.sol` for the target contract and function call

---

## License
This code is *NOT* audited! There are no warranties or assurances that this will work as expected!
Use only on testnet, since there are no tokens of value there.

MIT

## Contributing
If you do use it for something, would definitely be interested in seeing how you utilized it and if there are enhancements that could be made to the basic vault, open a PR and let's take a look!
