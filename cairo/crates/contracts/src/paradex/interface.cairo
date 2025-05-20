use starknet::ContractAddress;

#[starknet::interface]
pub trait IParaclear<TContractState> {
    fn decimals(self: @TContractState) -> u8;
    fn get_token_asset_balance(self: @TContractState, account: ContractAddress, token_address: ContractAddress) -> felt252;
    fn deposit_on_behalf_of(
        ref self: TContractState,
        recipient: ContractAddress,
        token_address: ContractAddress,
        amount: felt252,
    ) -> felt252;
}


