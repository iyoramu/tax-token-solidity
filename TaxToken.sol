// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Advanced Fee-on-Transfer Token (Tax Token)
 * @dev Implementation of an ERC20 token with advanced transfer fee functionality,
 * including dynamic fees, fee exemptions, and fee redistribution mechanisms.
 */
contract TaxToken is ERC20, Ownable {
    using SafeMath for uint256;

    // Fee structure
    struct FeeSettings {
        uint256 transferFeePercent; // Percentage of transfer amount to take as fee (1 = 0.1%, 10 = 1%)
        uint256 maxFeeAmount;       // Maximum absolute fee amount (in token units)
        address feeRecipient;       // Address that receives collected fees
        bool feeRecipientLocked;    // Whether fee recipient can be changed
    }

    // Exemption status for addresses
    struct Exemption {
        bool fromFees;  // Exempt from paying fees
        bool toFees;    // Exempt from receiving fees (for fee recipient)
    }

    FeeSettings public feeSettings;
    mapping(address => Exemption) public exemptions;

    // Events
    event FeeSettingsUpdated(
        uint256 transferFeePercent,
        uint256 maxFeeAmount,
        address feeRecipient
    );
    event ExemptionUpdated(address indexed account, bool fromFees, bool toFees);
    event FeesDistributed(address indexed from, address indexed to, uint256 amount, uint256 fee);

    /**
     * @dev Initializes the contract with initial settings.
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param initialSupply_ Initial token supply
     * @param initialFeeSettings Initial fee configuration
     * @param initialOwner Initial owner address
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        FeeSettings memory initialFeeSettings,
        address initialOwner
    ) ERC20(name_, symbol_) Ownable(initialOwner) {
        require(initialFeeSettings.transferFeePercent <= 1000, "TaxToken: fee cannot exceed 100%");
        require(initialFeeSettings.feeRecipient != address(0), "TaxToken: fee recipient cannot be zero");

        feeSettings = initialFeeSettings;
        
        // Mint initial supply to owner
        _mint(initialOwner, initialSupply_);
        
        // Exempt owner and fee recipient from fees by default
        exemptions[initialOwner] = Exemption(true, false);
        exemptions[initialFeeSettings.feeRecipient] = Exemption(false, true);
    }

    /**
     * @dev Updates fee settings (owner only).
     * @param newTransferFeePercent New fee percentage (1 = 0.1%, 10 = 1%)
     * @param newMaxFeeAmount New maximum fee amount
     * @param newFeeRecipient New fee recipient address
     */
    function updateFeeSettings(
        uint256 newTransferFeePercent,
        uint256 newMaxFeeAmount,
        address newFeeRecipient
    ) external onlyOwner {
        require(newTransferFeePercent <= 1000, "TaxToken: fee cannot exceed 100%");
        require(newFeeRecipient != address(0), "TaxToken: fee recipient cannot be zero");
        require(!feeSettings.feeRecipientLocked || newFeeRecipient == feeSettings.feeRecipient, 
            "TaxToken: fee recipient is locked");

        feeSettings.transferFeePercent = newTransferFeePercent;
        feeSettings.maxFeeAmount = newMaxFeeAmount;
        
        if (newFeeRecipient != feeSettings.feeRecipient) {
            // Remove exemption from old recipient
            exemptions[feeSettings.feeRecipient] = Exemption(false, false);
            // Add exemption for new recipient
            exemptions[newFeeRecipient] = Exemption(false, true);
            feeSettings.feeRecipient = newFeeRecipient;
        }

        emit FeeSettingsUpdated(newTransferFeePercent, newMaxFeeAmount, newFeeRecipient);
    }

    /**
     * @dev Locks the fee recipient address (owner only).
     */
    function lockFeeRecipient() external onlyOwner {
        feeSettings.feeRecipientLocked = true;
    }

    /**
     * @dev Sets exemption status for an address (owner only).
     * @param account Address to update
     * @param fromFees Whether exempt from paying fees
     * @param toFees Whether exempt from receiving fees (for fee recipient)
     */
    function setExemption(address account, bool fromFees, bool toFees) external onlyOwner {
        exemptions[account] = Exemption(fromFees, toFees);
        emit ExemptionUpdated(account, fromFees, toFees);
    }

    /**
     * @dev Overrides ERC20 transfer to implement fee logic.
     * @param recipient Address receiving the tokens
     * @param amount Amount of tokens to transfer
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        (uint256 sendAmount, uint256 feeAmount) = _calculateAmounts(_msgSender(), recipient, amount);
        
        _transfer(_msgSender(), recipient, sendAmount);
        
        if (feeAmount > 0) {
            _transfer(_msgSender(), feeSettings.feeRecipient, feeAmount);
            emit FeesDistributed(_msgSender(), recipient, amount, feeAmount);
        }
        
        return true;
    }

    /**
     * @dev Overrides ERC20 transferFrom to implement fee logic.
     * @param sender Address sending the tokens
     * @param recipient Address receiving the tokens
     * @param amount Amount of tokens to transfer
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        (uint256 sendAmount, uint256 feeAmount) = _calculateAmounts(sender, recipient, amount);
        
        _transfer(sender, recipient, sendAmount);
        
        if (feeAmount > 0) {
            _transfer(sender, feeSettings.feeRecipient, feeAmount);
            emit FeesDistributed(sender, recipient, amount, feeAmount);
        }
        
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount));
        return true;
    }

    /**
     * @dev Calculates the amounts to send and the fee.
     * @param sender Address sending the tokens
     * @param recipient Address receiving the tokens
     * @param amount Total amount to transfer
     * @return sendAmount Amount that will be sent to recipient
     * @return feeAmount Amount that will be taken as fee
     */
    function _calculateAmounts(
        address sender,
        address recipient,
        uint256 amount
    ) internal view returns (uint256 sendAmount, uint256 feeAmount) {
        if (exemptions[sender].fromFees || exemptions[recipient].fromFees) {
            return (amount, 0);
        }

        feeAmount = amount.mul(feeSettings.transferFeePercent).div(1000);
        
        if (feeSettings.maxFeeAmount > 0 && feeAmount > feeSettings.maxFeeAmount) {
            feeAmount = feeSettings.maxFeeAmount;
        }
        
        sendAmount = amount.sub(feeAmount);
    }

    /**
     * @dev Burns tokens from caller's balance.
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Burns tokens from specified address (owner only).
     * @param account Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    /**
     * @dev Mints new tokens (owner only).
     * @param account Address to receive minted tokens
     * @param amount Amount to mint
     */
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }
}
