# ckETH

Ethereum integration (ckETH and ckERC20) for motoko implementation

## About Ethereum Integration

A true World Computer enables a multi-chain environment where centralized bridges are obsolete and smart contracts can seamlessly communicate across blockchains. ICP already integrates with the Bitcoin Network, and native ETH integration is underway.

https://internetcomputer.org/ethereum-integration

## Introduction

The integration of ethereum on the IC network without bridges is achieved through chain-key (threshold signature) technology for ECDSA signatures, and the smart contracts of IC can directly access the RPC nodes of ethereum through HTTPS Outcall technology. This is the technical solution implemented in stage 1, which can be decentralized by configuring multiple RPC API providers. 

The user sends an ethereum asset, ETH or ERC20 token, to an address controlled by the IC smart contract (Minter), which receives the ethereum asset and mint ckETH or ckERC20 token on the IC network at a 1:1 ratio. When users want to retrieve the real ethereum asset, they only need to return ckETH or ckERC20 token to Minter smart contract to retrieve the ethereum assets.

### Minter Smart Contract

By chain-key (threshold signature) technology to manage the transfer of assets between the ethereum and IC networks, no one holds the private key of the Minter smart contract's account on ethereum, and its private key fragments are held by the IC network nodes. So its security depends on the security of the IC network.

### ckETH & ckERC20

ckETH/ckERC20 is an ICRC1 standard token running on the IC network, a token created when an ethereum asset crosses the chain to the IC network, and is minted and destroyed by the Minter smart contract, maintaining a 1:1 relationship with the real ethereum asset.

## Roadmap

- ckETH Minting and Retrieval (done)
- ckERC20 Minting and Retrieval (done)
- Decentralization with multiple RPC API providers (done)

## Demo

http://iclight.io

## Related technologies used

- Threshold ECDSA https://github.com/dfinity/examples/tree/master/motoko/threshold-ecdsa
- EVM Utils https://github.com/icopen/evm_utils_ic
- IC-Web3 https://github.com/rocklabs-io/ic-web3

