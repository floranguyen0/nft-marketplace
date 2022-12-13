// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IRegistry.sol";

contract Registry is Ownable {
    bool allowAllCurrencies;
    address systemWallet;
    // 3% tax on a 18 decimal asset
    uint256 fee = 300;
    uint256 scale = 1e4;

    event SystemWalletUpdated(address newWallet);
    event FeeVariablesChanged(uint256 indexed newFee, uint256 indexed newScale);
    event ContractStatusChanged(address indexed changed, bool indexed status);
    event CurrencyStatusChanged(address indexed changed, bool indexed status);

    mapping(address => bool) public platformContracts;
    mapping(address => bool) public approvedCurrencies;

    constructor() {
        approvedCurrencies[
            address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)
        ] = true;
    }

    function setSystemWallet(address newWallet) external onlyOwner {
        systemWallet = newWallet;

        emit SystemWalletUpdated(newWallet);
    }

    function setFeeVariables(uint256 newFee, uint256 newScale)
        external
        onlyOwner
    {
        fee = newFee;
        scale = newScale;

        emit FeeVariablesChanged(newFee, newScale);
    }

    function setContractStatus(address toChange, bool status)
        external
        onlyOwner
    {
        if (platformContracts[toChange] != status) {
            platformContracts[toChange] = status;
            emit ContractStatusChanged(toChange, status);
        }
    }

    function setCurrencyStatus(address tokenContract, bool status)
        external
        onlyOwner
    {
        require(!allowAllCurrencies, "All currencies are approved");

        if (approvedCurrencies[tokenContract] == status) {
            approvedCurrencies[tokenContract] = status;
            emit CurrencyStatusChanged(tokenContract, status);
        }
    }

    function approveAllCurrencies() external onlyOwner {
        if (!allowAllCurrencies) {
            allowAllCurrencies = true;
            emit CurrencyStatusChanged(address(0), true);
        }
    }

    function feeInfo(uint256 salePrice)
        external
        view
        returns (address, uint256)
    {
        return (systemWallet, ((salePrice * fee) / scale));
    }
}