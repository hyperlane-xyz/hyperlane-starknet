use contracts::paradex::interface::IParaclear;
use contracts::utils::utils::U256TryIntoContractAddress;
use core::{num::traits::Pow, starknet::event::EventEmitter};
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use starknet::ContractAddress;
use starknet::get_contract_address;


#[starknet::interface]
pub trait IMockParadexDex<TContractState> {
    fn set_decimals(ref self: TContractState, decimals: u8);
}

#[starknet::contract]
pub mod MockParadexDex {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use super::*;

    pub mod Errors {
        pub const INSUFFICIENT_ALLOWANCE: felt252 = 'Insufficient allowance';
    }

    #[storage]
    struct Storage {
        token_decimals: u8,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        DepositSuccess: DepositSuccess,
    }

    #[derive(Drop, starknet::Event)]
    pub struct DepositSuccess {
        pub token: ContractAddress,
        pub recipient: ContractAddress,
        pub amount: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, decimals: u8) {
        self.token_decimals.write(8);
    }

    #[abi(embed_v0)]
    impl IParaclearImpl of IParaclear<ContractState> {
        fn decimals(self: @ContractState) -> u8 {
            self.token_decimals.read()
        }

        fn get_token_asset_balance(
            self: @ContractState, account: ContractAddress, token_address: ContractAddress,
        ) -> felt252 {
            let token_dispatcher = ERC20ABIDispatcher { contract_address: token_address };
            token_dispatcher.balance_of(starknet::get_contract_address()).try_into().unwrap()
        }

        fn deposit_on_behalf_of(
            ref self: ContractState,
            recipient: ContractAddress,
            token_address: ContractAddress,
            amount: felt252,
        ) -> felt252 {
            let token_dispatcher = ERC20ABIDispatcher { contract_address: token_address };
            let token_decimal = token_dispatcher.decimals();
            let dex_decimal = self.token_decimals.read();
            let amount_u256: u256 = amount.try_into().unwrap();
            // scale back paradex amount to token amount
            let scale_back_amount = if token_decimal < dex_decimal {
                amount_u256 / (10_u256.pow((dex_decimal - token_decimal).into()))
            } else if token_decimal > dex_decimal {
                amount_u256 * (10_u256.pow((token_decimal - dex_decimal).into()))
            } else {
                amount_u256
            };

            // check for the allowance of the token
            let allowance = token_dispatcher
                .allowance(starknet::get_caller_address(), get_contract_address());
            assert(allowance >= scale_back_amount, Errors::INSUFFICIENT_ALLOWANCE);
            token_dispatcher
                .transfer_from(
                    starknet::get_caller_address(),
                    starknet::get_contract_address(),
                    scale_back_amount,
                );

            self
                .emit(
                    DepositSuccess {
                        token: token_address, recipient: recipient, amount: amount_u256,
                    },
                );
            return amount;
        }
    }

    #[abi(embed_v0)]
    impl IMockParadexDexImpl of super::IMockParadexDex<ContractState> {
        fn set_decimals(ref self: ContractState, decimals: u8) {
            self.token_decimals.write(decimals);
        }
    }
}
