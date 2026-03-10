// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

interface IPolyFactoryHelper {
    function getPolyProxyWalletAddress(address _addr) external view returns (address);

    function getSafeAddress(address _addr) external view returns (address);
}
