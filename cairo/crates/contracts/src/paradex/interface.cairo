use starknet::ContractAddress;

#[starknet::interface]
pub trait IParaclear<TContractState> {
    fn decimals(self: @TContractState) -> u8;
}


