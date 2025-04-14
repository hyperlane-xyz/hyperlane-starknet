use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use starknet::get_contract_address;
use contracts::utils::utils::U256TryIntoContractAddress;


#[starknet::interface]
pub trait IMockParadexDex<TContractState> {
    fn deposit_on_behalf_of(
        ref self: TContractState,
        recipient: ContractAddress,
        token_address: ContractAddress,
        amount: felt252
    ) -> felt252;

    fn set_hyperlane_token(
        ref self: TContractState,
        token_address: ContractAddress
    );
    
}

#[starknet::contract]
mod MockParadexDex {
    use super::*;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    pub mod Errors {
        pub const CALLER_NOT_HYPERLANE: felt252 = 'Caller not hyperlane';
        pub const INSUFFICIENT_ALLOWANCE: felt252 = 'Insufficient allowance';
    }

    #[storage]
    struct Storage {
        hyperlane_token_address: ContractAddress,
    }
    

    #[constructor]
    fn constructor(ref self: ContractState) {
    }

    fn set_hyperlane_token(ref self: ContractState, token_address: ContractAddress) {
        self.hyperlane_token_address.write(token_address);
    }

    impl IMockParadexDexImpl of super::IMockParadexDex<ContractState> {
        fn deposit_on_behalf_of(ref self: ContractState, recipient: ContractAddress, token_address: ContractAddress, amount: felt252) -> felt252 {
            // check if the sender is the hyperlane token address
            assert(
                starknet::get_caller_address() != self.hyperlane_token_address.read(), 
                Errors::CALLER_NOT_HYPERLANE
            );


            let token_dispatcher = ERC20ABIDispatcher { contract_address: token_address };
            // check for the allowance of the token
            let allowance = token_dispatcher.allowance(starknet::get_caller_address(), get_contract_address());
            let amount_u256: u256 = amount.try_into().unwrap();
            assert(
                allowance >= amount_u256,
                Errors::INSUFFICIENT_ALLOWANCE
            );
            token_dispatcher.transfer(recipient, amount_u256);
            
            return amount;
        }
    }
}