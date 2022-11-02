// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/mrkt_interfaces/IRegistry.sol";

/// @title Registry for an NFT matketplace
/// @author Linum Labs
contract Registry is IRegistry, Ownable {
    mapping(address => bool) private platformContracts;
    mapping(address => bool) private approvedCurrencies;
    bool allowAllCurrencies;
    address systemWallet;
    // scale: how many zeroes should follow the fee
    // in the default values, there would be a 3% tax on a 18 decimal asset
    uint256 fee = 300;
    uint256 scale = 1e4;

    constructor() {
        approvedCurrencies[address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa)] = true;
    }

    function isPlatformContract(address toCheck) external view override returns (bool) {
        return platformContracts[toCheck];
    }

    function isApprovedCurrency(address tokenContract) external view override returns (bool) {
        if (allowAllCurrencies) return true;
        return approvedCurrencies[tokenContract];
    }

    function feeInfo(uint256 _salePrice) external view override returns (address, uint256) {
        return (systemWallet, ((_salePrice * fee) / scale));
    }

    function setSystemWallet(address newWallet) external override onlyOwner {
        systemWallet = newWallet;

        emit SystemWalletUpdated(newWallet);
    }

    function setFeeVariables(uint256 newFee, uint256 newScale) external override onlyOwner {
        fee = newFee;
        scale = newScale;
        emit FeeVariablesChanged(newFee, newScale);
    }

    function setContractStatus(address toChange, bool status) external override onlyOwner {
        string memory boolString = status == true ? "true" : "false";
        require(
            platformContracts[toChange] != status,
            string(abi.encodePacked("contract status is already ", boolString))
        );
        platformContracts[toChange] = status;
        emit ContractStatusChanged(toChange, status);
    }

    function setCurrencyStatus(address tokenContract, bool status) external override onlyOwner {
        require(!allowAllCurrencies, "all currencies approved");
        string memory boolString = status == true ? "true" : "false";
        require(
            approvedCurrencies[tokenContract] != status,
            string(abi.encodePacked("token status is already ", boolString))
        );
        approvedCurrencies[tokenContract] = status;
        emit CurrencyStatusChanged(tokenContract, status);
    }

    function approveAllCurrencies() external override onlyOwner {
        require(!allowAllCurrencies, "already approved");
        allowAllCurrencies = true;
        emit CurrencyStatusChanged(address(0), true);
    }
}