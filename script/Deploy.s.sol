// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/JBBuybackHook.sol";

contract Deploy is Script {

    function run() public {
        uint256 chainId = block.chainid;
        string memory chain;
        address wethAddress;
        address factoryAddress;

           // Ethereum Mainnet
        if (chainId == 1) {
            chain = "1";
            wethAddress = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            factoryAddress = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
           // Ethereum Sepolia
        } else if (chainId == 11_155_111) {
            chain = "11155111";
            wethAddress = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
            factoryAddress = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;
           // Optimism Mainnet
        } else if (chainId == 420) {
            chain = "420";
            wethAddress = 0x4200000000000000000000000000000000000006;
            factoryAddress = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Optimism Sepolia
        } else if (chainId == 11_155_420) {
            chain = "11155420";
            wethAddress = 0x4200000000000000000000000000000000000006;
            factoryAddress = address(0);
            // Polygon Mainnet
        } else if (chainId == 137) {
            chain = "137";
            wethAddress = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
            factoryAddress = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
            // Polygon Mumbai
        } else if (chainId == 80_001) {
            chain = "80001"; 
            wethAddress = 0xA6FA4fB5f76172d178d61B04b0ecd319C5d1C0aa;
            factoryAddress = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
        } else {
            revert("Invalid RPC / no juice contracts deployed on this network");
        }

        address directoryAddress =
            stdJson.readAddress(
            vm.readFile(
                string.concat(
                    "lib/juice-contracts-v4/broadcast/Deploy.s.sol/", chain, "/run-latest.json"
                )
            ),
            ".transactions[2].contractAddress"
        );

        address controllerAddress = (
            stdJson.readAddress(
            vm.readFile(
                string.concat(
                    "lib/juice-contracts-v4/broadcast/Deploy.s.sol/", chain, "/run-latest.json"
                )
            ),
            ".transactions[7].contractAddress"
            )
        );

        vm.broadcast();
        new JBBuybackHook(IWETH9(wethAddress), factoryAddress, IJBDirectory(directoryAddress), IJBController(controllerAddress));
    }
}
