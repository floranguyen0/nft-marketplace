// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRegistry.sol";

/// @title Registry for an NFT matketplace
/// @author Linum Labs
contract Registry is IRegistry, Ownable {
    mapping(address => bool) private platformContracts;
    mapping(address => bool) private approvedCurrencies;
    bool allowAllCurrencies;
    address systemWallet;
    // 3% tax on a 18 decimal asset
    uint256 fee = 300;
    uint256 scale = 1e4;

    constructor() {
        approvedCurrencies[
            address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)
        ] = true;
    }

    function setSystemWallet(address newWallet) external override onlyOwner {
        systemWallet = newWallet;

        emit SystemWalletUpdated(newWallet);
    }

    function setFeeVariables(uint256 newFee, uint256 newScale)
        external
        override
        onlyOwner
    {
        fee = newFee;
        scale = newScale;

        emit FeeVariablesChanged(newFee, newScale);
    }

    function setContractStatus(address toChange, bool status)
        external
        override
        onlyOwner
    {
        if (platformContracts[toChange] != status) {
            platformContracts[toChange] = status;
            emit ContractStatusChanged(toChange, status);
        }
    }

    function setCurrencyStatus(address tokenContract, bool status)
        external
        override
        onlyOwner
    {
        require(!allowAllCurrencies, "All currencies are approved");

        if (approvedCurrencies[tokenContract] == status) {
            approvedCurrencies[tokenContract] = status;
            emit CurrencyStatusChanged(tokenContract, status);
        }
    }

    function approveAllCurrencies() external override onlyOwner {
        if (!allowAllCurrencies) {
            allowAllCurrencies = true;
            emit CurrencyStatusChanged(address(0), true);
        }
    }

    function isPlatformContract(address toCheck)
        external
        view
        override
        returns (bool)
    {
        return platformContracts[toCheck];
    }

    function isApprovedCurrency(address tokenContract)
        external
        view
        override
        returns (bool)
    {
        if (allowAllCurrencies) return true;
        return approvedCurrencies[tokenContract];
    }

    function feeInfo(uint256 salePrice)
        external
        view
        override
        returns (address, uint256)
    {
        return (systemWallet, ((salePrice * fee) / scale));
    }
}
