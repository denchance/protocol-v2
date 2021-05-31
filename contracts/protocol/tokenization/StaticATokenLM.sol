// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {ILendingPool} from '../../interfaces/ILendingPool.sol';
import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {ERC20} from '../../dependencies/openzeppelin/contracts/ERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {WadRayMath} from '../../protocol/libraries/math/WadRayMath.sol';
import {RayMathNoRounding} from '../../protocol/libraries/math/RayMathNoRounding.sol';

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';

interface IAaveIncentivesController {
  function claimRewards(
    address[] calldata assets,
    uint256 amount,
    address to
  ) external returns (uint256);

  function REWARD_TOKEN() external view returns (address);
}

interface IAToken is IERC20 {
  function POOL() external view returns (ILendingPool);

  function UNDERLYING_ASSET_ADDRESS() external view returns (address);

  function getIncentivesController() external view returns (IAaveIncentivesController);
}

contract StaticATokenLM is ERC20 {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;
  using WadRayMath for uint256;
  using RayMathNoRounding for uint256;

  struct SignatureParams {
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  bytes public constant EIP712_REVISION = bytes('1');
  bytes32 internal constant EIP712_DOMAIN =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');
  bytes32 public constant METADEPOSIT_TYPEHASH =
    keccak256(
      'Deposit(address depositor,address recipient,uint256 value,uint16 referralCode,bool fromUnderlying,uint256 nonce,uint256 deadline)'
    );
  bytes32 public constant METAWITHDRAWAL_TYPEHASH =
    keccak256(
      'Withdraw(address owner,address recipient,uint256 staticAmount,uint256 dynamicAmount,bool toUnderlying,uint256 nonce,uint256 deadline)'
    );

  ILendingPool public immutable LENDING_POOL;
  IERC20 public immutable ATOKEN;
  IERC20 public immutable ASSET;

  mapping(address => uint256) public _nonces;

  // Handling Liquidity Mining incentives. Unclear how we can handle multiple reward assets
  uint256 public accRewardstokenPerShare;
  uint256 public lastRewardBlock;
  mapping(address => uint256) public rewardDebts; //Rays
  mapping(address => uint256) public unclaimedRewards; //Rays
  IAaveIncentivesController internal _incentivesController;

  // TODO: Implement the ability to change this. Should probably be a list of the reward tokens, [first, second, third...], where we can loop backwards to see if a user gas been there since before a change.
  address public immutable currentRewardToken;

  constructor(
    ILendingPool lendingPool,
    address aToken,
    string memory wrappedTokenName,
    string memory wrappedTokenSymbol
  ) public ERC20(wrappedTokenName, wrappedTokenSymbol) {
    LENDING_POOL = lendingPool;
    ATOKEN = IERC20(aToken);

    IERC20 underlyingAsset = IERC20(IAToken(aToken).UNDERLYING_ASSET_ADDRESS());
    ASSET = underlyingAsset;
    underlyingAsset.approve(address(lendingPool), type(uint256).max); // Could an attacker max this out with flashminting or so?

    _incentivesController = IAToken(aToken).getIncentivesController();
    currentRewardToken = _incentivesController.REWARD_TOKEN();
  }

  /**
   * @dev Deposits `ASSET` in the Aave protocol and mints static aTokens to msg.sender
   * @param recipient The address that will receive the static aTokens
   * @param amount The amount of underlying `ASSET` to deposit (e.g. deposit of 100 USDC)
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   * @param fromUnderlying bool
   * - `true` if the msg.sender comes with underlying tokens (e.g. USDC)
   * - `false` if the msg.sender comes already with aTokens (e.g. aUSDC)
   * @return uint256 The amount of StaticAToken minted, static balance
   **/
  function deposit(
    address recipient,
    uint256 amount,
    uint16 referralCode,
    bool fromUnderlying
  ) external returns (uint256) {
    return _deposit(msg.sender, recipient, amount, referralCode, fromUnderlying);
  }

  /**
   * @dev Burns `amount` of static aToken, with recipient receiving the corresponding amount of `ASSET`
   * @param recipient The address that will receive the amount of `ASSET` withdrawn from the Aave protocol
   * @param amount The amount to withdraw, in static balance of StaticAToken
   * @param toUnderlying bool
   * - `true` for the recipient to get underlying tokens (e.g. USDC)
   * - `false` for the recipient to get aTokens (e.g. aUSDC)
   * @return amountToBurn: StaticATokens burnt, static balance
   * @return amountToWithdraw: underlying/aToken send to `recipient`, dynamic balance
   **/
  function withdraw(
    address recipient,
    uint256 amount,
    bool toUnderlying
  ) external returns (uint256, uint256) {
    return _withdraw(msg.sender, recipient, amount, 0, toUnderlying);
  }

  /**
   * @dev Burns `amount` of static aToken, with recipient receiving the corresponding amount of `ASSET`
   * @param recipient The address that will receive the amount of `ASSET` withdrawn from the Aave protocol
   * @param amount The amount to withdraw, in dynamic balance of aToken/underlying asset
   * @param toUnderlying bool
   * - `true` for the recipient to get underlying tokens (e.g. USDC)
   * - `false` for the recipient to get aTokens (e.g. aUSDC)
   * @return amountToBurn: StaticATokens burnt, static balance
   * @return amountToWithdraw: underlying/aToken send to `recipient`, dynamic balance
   **/
  function withdrawDynamicAmount(
    address recipient,
    uint256 amount,
    bool toUnderlying
  ) external returns (uint256, uint256) {
    return _withdraw(msg.sender, recipient, 0, amount, toUnderlying);
  }

  /**
   * @dev Implements the permit function as for
   * https://github.com/ethereum/EIPs/blob/8a34d644aacf0f9f8f00815307fd7dd5da07655f/EIPS/eip-2612.md
   * @param owner The owner of the funds
   * @param spender The spender
   * @param value The amount
   * @param deadline The deadline timestamp, type(uint256).max for max deadline
   * @param v Signature param
   * @param s Signature param
   * @param r Signature param
   * @param chainId Passing the chainId in order to be fork-compatible
   */
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s,
    uint256 chainId
  ) external {
    require(owner != address(0), 'INVALID_OWNER');
    //solium-disable-next-line
    require(block.timestamp <= deadline, 'INVALID_EXPIRATION');
    uint256 currentValidNonce = _nonces[owner];
    bytes32 digest =
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          getDomainSeparator(chainId),
          keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, currentValidNonce, deadline))
        )
      );
    require(owner == ecrecover(digest, v, r, s), 'INVALID_SIGNATURE');
    _nonces[owner] = currentValidNonce.add(1);
    _approve(owner, spender, value);
  }

  /**
   * @dev Allows to deposit on Aave via meta-transaction
   * https://github.com/ethereum/EIPs/blob/8a34d644aacf0f9f8f00815307fd7dd5da07655f/EIPS/eip-2612.md
   * @param depositor Address from which the funds to deposit are going to be pulled
   * @param recipient Address that will receive the staticATokens, in the average case, same as the `depositor`
   * @param value The amount to deposit
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   * @param fromUnderlying bool
   * - `true` if the msg.sender comes with underlying tokens (e.g. USDC)
   * - `false` if the msg.sender comes already with aTokens (e.g. aUSDC)
   * @param deadline The deadline timestamp, type(uint256).max for max deadline
   * @param sigParams Signature params: v,r,s
   * @param chainId Passing the chainId in order to be fork-compatible
   * @return uint256 The amount of StaticAToken minted, static balance
   */
  function metaDeposit(
    address depositor,
    address recipient,
    uint256 value,
    uint16 referralCode,
    bool fromUnderlying,
    uint256 deadline,
    SignatureParams calldata sigParams,
    uint256 chainId
  ) external returns (uint256) {
    require(depositor != address(0), 'INVALID_DEPOSITOR');
    //solium-disable-next-line
    require(block.timestamp <= deadline, 'INVALID_EXPIRATION');
    uint256 currentValidNonce = _nonces[depositor];
    bytes32 digest =
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          getDomainSeparator(chainId),
          keccak256(
            abi.encode(
              METADEPOSIT_TYPEHASH,
              depositor,
              recipient,
              value,
              referralCode,
              fromUnderlying,
              currentValidNonce,
              deadline
            )
          )
        )
      );
    require(
      depositor == ecrecover(digest, sigParams.v, sigParams.r, sigParams.s),
      'INVALID_SIGNATURE'
    );
    _nonces[depositor] = currentValidNonce.add(1);
    _deposit(depositor, recipient, value, referralCode, fromUnderlying);
  }

  /**
   * @dev Allows to withdraw from Aave via meta-transaction
   * https://github.com/ethereum/EIPs/blob/8a34d644aacf0f9f8f00815307fd7dd5da07655f/EIPS/eip-2612.md
   * @param owner Address owning the staticATokens
   * @param recipient Address that will receive the underlying withdrawn from Aave
   * @param staticAmount The amount of staticAToken to withdraw. If > 0, `dynamicAmount` needs to be 0
   * @param dynamicAmount The amount of underlying/aToken to withdraw. If > 0, `staticAmount` needs to be 0
   * @param toUnderlying bool
   * - `true` for the recipient to get underlying tokens (e.g. USDC)
   * - `false` for the recipient to get aTokens (e.g. aUSDC)
   * @param deadline The deadline timestamp, type(uint256).max for max deadline
   * @param sigParams Signature params: v,r,s
   * @param chainId Passing the chainId in order to be fork-compatible
   * @return amountToBurn: StaticATokens burnt, static balance
   * @return amountToWithdraw: underlying/aToken send to `recipient`, dynamic balance
   */
  function metaWithdraw(
    address owner,
    address recipient,
    uint256 staticAmount,
    uint256 dynamicAmount,
    bool toUnderlying,
    uint256 deadline,
    SignatureParams calldata sigParams,
    uint256 chainId
  ) external returns (uint256, uint256) {
    require(owner != address(0), 'INVALID_OWNER');
    //solium-disable-next-line
    require(block.timestamp <= deadline, 'INVALID_EXPIRATION');
    uint256 currentValidNonce = _nonces[owner];
    bytes32 digest =
      keccak256(
        abi.encodePacked(
          '\x19\x01',
          getDomainSeparator(chainId),
          keccak256(
            abi.encode(
              METAWITHDRAWAL_TYPEHASH,
              owner,
              recipient,
              staticAmount,
              dynamicAmount,
              toUnderlying,
              currentValidNonce,
              deadline
            )
          )
        )
      );

    require(owner == ecrecover(digest, sigParams.v, sigParams.r, sigParams.s), 'INVALID_SIGNATURE');
    _nonces[owner] = currentValidNonce.add(1);
    return _withdraw(owner, recipient, staticAmount, dynamicAmount, toUnderlying);
  }

  /**
   * @dev Utility method to get the current aToken balance of an user, from his staticAToken balance
   * @param account The address of the user
   * @return uint256 The aToken balance
   **/
  function dynamicBalanceOf(address account) external view returns (uint256) {
    return _staticToDynamicAmount(balanceOf(account), rate());
  }

  /**
   * @dev Converts a static amount (scaled balance on aToken) to the aToken/underlying value,
   * using the current liquidity index on Aave
   * @param amount The amount to convert from
   * @return uint256 The dynamic amount
   **/
  function staticToDynamicAmount(uint256 amount) public view returns (uint256) {
    return _staticToDynamicAmount(amount, rate());
  }

  /**
   * @dev Converts an aToken or underlying amount to the what it is denominated on the aToken as
   * scaled balance, function of the principal and the liquidity index
   * @param amount The amount to convert from
   * @return uint256 The static (scaled) amount
   **/
  function dynamicToStaticAmount(uint256 amount) public view returns (uint256) {
    return _dynamicToStaticAmount(amount, rate());
  }

  /**
   * @dev Returns the Aave liquidity index of the underlying aToken, denominated rate here
   * as it can be considered as an ever-increasing exchange rate
   * @return bytes32 The domain separator
   **/
  function rate() public view returns (uint256) {
    return LENDING_POOL.getReserveNormalizedIncome(address(ASSET));
  }

  /**
   * @dev Function to return a dynamic domain separator, in order to be compatible with forks changing chainId
   * @param chainId The chain id
   * @return bytes32 The domain separator
   **/
  function getDomainSeparator(uint256 chainId) public view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          EIP712_DOMAIN,
          keccak256(bytes(name())),
          keccak256(EIP712_REVISION),
          chainId,
          address(this)
        )
      );
  }

  function _dynamicToStaticAmount(uint256 amount, uint256 rate) internal pure returns (uint256) {
    return amount.rayDiv(rate);
  }

  function _staticToDynamicAmount(uint256 amount, uint256 rate) internal pure returns (uint256) {
    return amount.rayMul(rate);
  }

  function _deposit(
    address depositor,
    address recipient,
    uint256 amount,
    uint16 referralCode,
    bool fromUnderlying
  ) internal returns (uint256) {
    require(recipient != address(0), 'INVALID_RECIPIENT');
    updateRewards();

    _updateUnclaimedRewards(recipient);

    if (fromUnderlying) {
      ASSET.safeTransferFrom(depositor, address(this), amount);
      LENDING_POOL.deposit(address(ASSET), amount, address(this), referralCode);
    } else {
      ATOKEN.safeTransferFrom(depositor, address(this), amount);
    }
    uint256 amountToMint = _dynamicToStaticAmount(amount, rate());
    _mint(recipient, amountToMint);

    _updateRewardDebt(recipient, balanceOf(recipient));

    return amountToMint;
  }

  function _withdraw(
    address owner,
    address recipient,
    uint256 staticAmount,
    uint256 dynamicAmount,
    bool toUnderlying
  ) internal returns (uint256, uint256) {
    require(recipient != address(0), 'INVALID_RECIPIENT');
    require(staticAmount == 0 || dynamicAmount == 0, 'ONLY_ONE_AMOUNT_FORMAT_ALLOWED');
    updateRewards();

    _updateUnclaimedRewards(owner);

    uint256 userBalance = balanceOf(owner);

    uint256 amountToWithdraw;
    uint256 amountToBurn;

    uint256 currentRate = rate();
    if (staticAmount > 0) {
      amountToBurn = (staticAmount > userBalance) ? userBalance : staticAmount;
      amountToWithdraw = (staticAmount > userBalance)
        ? _staticToDynamicAmount(userBalance, currentRate)
        : _staticToDynamicAmount(staticAmount, currentRate);
    } else {
      uint256 dynamicUserBalance = _staticToDynamicAmount(userBalance, currentRate);
      amountToWithdraw = (dynamicAmount > dynamicUserBalance) ? dynamicUserBalance : dynamicAmount;
      amountToBurn = _dynamicToStaticAmount(amountToWithdraw, currentRate);
    }

    _burn(owner, amountToBurn);

    if (toUnderlying) {
      LENDING_POOL.withdraw(address(ASSET), amountToWithdraw, recipient);
    } else {
      ATOKEN.safeTransfer(recipient, amountToWithdraw);
    }

    _updateRewardDebt(owner, balanceOf(owner));
    return (amountToBurn, amountToWithdraw);
  }

  /**
   * @dev Updates rewards for senders and receiver in a transfer (no mint or burn)
   * @param from The address of the sender of tokens
   * @param to The address of the receiver of tokens
   * @param amount The amount of tokens to transfer in WAD
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override {
    // Only enter when not minting or burning.
    if (from != address(0) && to != address(0)) {
      // The rewards not claimed to the contract yet is transferrred to the buyer as well.
      // Often the recent rewards < gas, so only needed for whales to run updateClaim before it

      // Pay out rewards (from)
      _updateUnclaimedRewards(from);
      _updateRewardDebt(from, balanceOf(from).sub(amount));

      // Pay out rewards (to)
      _updateUnclaimedRewards(to);
      _updateRewardDebt(to, balanceOf(to).add(amount));
    }
  }

  /**
   * @dev Claims rewards from the `_incentivesController` and update `accRewardstokenPerShare`
   */
  function updateRewards() public {
    // Only need to claim rewards when once per block. Check with the _incentivesController
    if (block.number > lastRewardBlock) {
      lastRewardBlock = block.number;
      uint256 _supply = totalSupply();
      if (_supply == 0) {
        return;
      }

      address[] memory assets = new address[](1);
      assets[0] = address(ATOKEN);

      uint256 freshReward =
        _incentivesController.claimRewards(assets, type(uint256).max, address(this)).wadToRay();
      accRewardstokenPerShare = accRewardstokenPerShare.add(
        freshReward.rayDivNoRounding(_supply.wadToRay())
      );
    }
  }

  /**
   * @dev Update the rewards and claim rewards
   * @param user The address of the user to claim rewards for
   */
  function updateAndClaimRewards(address user) public {
    updateRewards();
    claimRewards(user);
  }

  /**
   * @dev Claim rewards without retrieving the latest accrued rewards
   * makes sense for small holders
   * @param user The address of the user to claim rewards for
   */
  function claimRewards(address user) public {
    // Claim rewards without collecting the latest rewards
    uint256 balance = balanceOf(user);
    uint256 reward = _getClaimableRewards(user, balance); // Remember that this is converting to wad
    if (reward > 0) {
      unclaimedRewards[user] = 0;
      _safeRewardTransfer(user, reward);
      _updateRewardDebt(user, balance);
    }
  }

  /**
   * @dev Safe transfer of the rewards, taking into account rounding errors to
   * allow the last user to retrieve funds if 1 wei off etc
   * @param to The address to receive rewards
   * @param amount The amount of rewards to receive in WAD
   */
  function _safeRewardTransfer(address to, uint256 amount) internal {
    uint256 rewardBal = IERC20(currentRewardToken).balanceOf(address(this));
    if (amount > rewardBal) {
      IERC20(currentRewardToken).safeTransfer(to, rewardBal);
    } else {
      IERC20(currentRewardToken).safeTransfer(to, amount);
    }
  }

  /**
   * @dev Update the rewardDebt for a user with balance as his balance
   * @param user The user to update
   * @param balance The balance of the user
   */
  function _updateRewardDebt(address user, uint256 balance) internal {
    // If we round down here, we could underestimate the debt, thereby paying out too much. Better to overestimate.
    uint256 rayBalance = balance.wadToRay();
    rewardDebts[user] = rayBalance.rayMul(accRewardstokenPerShare);
  }

  /**
   * @dev Adding the pending rewards to the unclaimed for specific user
   * @param user The address of the user to update
   */
  function _updateUnclaimedRewards(address user) internal {
    uint256 balance = balanceOf(user);
    if (balance > 0) {
      uint256 pending = _getPendingRewards(user, balance);
      unclaimedRewards[user] = unclaimedRewards[user].add(pending);
    }
  }

  /**
   * @dev Compute the pending in RAY (rounded down). Pending is the amount to add  (not yet unclaimed) rewards in RAY (rounded down).
   * @param user The user to compute for
   * @param balance The balance of the user
   * @return The amound of pending rewards in RAY
   */
  function _getPendingRewards(address user, uint256 balance) internal view returns (uint256) {
    // Compute the pending rewards in ray, rounded down.
    uint256 rayBalance = balance.wadToRay();
    uint256 _reward = rayBalance.rayMulNoRounding(accRewardstokenPerShare);
    uint256 _debt = rewardDebts[user];
    if (_reward > _debt) {
      // Safe because line above
      return _reward - _debt;
    }
    return 0;
  }

  function _getClaimableRewards(address user, uint256 balance) internal view returns (uint256) {
    uint256 reward = unclaimedRewards[user].add(_getPendingRewards(user, balance));
    return reward.rayToWadNoRounding();
  }

  /**
   * @dev Get the total claimable rewards for a user in WAD
   * @param user The address of the user
   * @return The claimable amount of rewards in WAD
   */
  function getClaimableRewards(address user) public view returns (uint256) {
    return _getClaimableRewards(user, balanceOf(user));
  }
}
