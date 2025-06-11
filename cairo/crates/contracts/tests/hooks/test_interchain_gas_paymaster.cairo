use contracts::hooks::interchain_gas_paymaster::interchain_gas_paymaster as igp_mod;
use igp_mod::{GasPayment, TokensClaimed};
use contracts::interfaces::{
    IInterchainGasPaymasterDispatcherTrait, IPostDispatchHookDispatcherTrait, Types
};
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{CheatSpan, EventSpyAssertionsTrait, cheat_caller_address, spy_events};
use starknet::ContractAddress;
use contracts::utils::utils::U256TryIntoContractAddress;

use super::super::setup::{DESTINATION_DOMAIN, OWNER, BENEFICIARY, setup_interchain_gas_paymaster,};

#[test]
fn test_hook_type() {
    let (_, post_hook, _) = setup_interchain_gas_paymaster();
    assert_eq!(post_hook.hook_type(), Types::INTERCHAIN_GAS_PAYMASTER(()));
}

#[test]
fn test_quote_gas_payment() {
    let (igp, _, _) = setup_interchain_gas_paymaster();
    let gas_limit: u256 = 50_000;

    let overhead: u256 = 1_000;
    let gas_price: u256 = 1_000;
    let expected: u256 = (gas_limit + overhead) * gas_price;

    assert_eq!(igp.quote_gas_payment(DESTINATION_DOMAIN, gas_limit + overhead), expected);
}

#[test]
#[should_panic(expected: 'IGP: conf not found for domain')]
fn test_quote_gas_payment_fails_without_config() {
    let (igp, _, _) = setup_interchain_gas_paymaster();
    igp.quote_gas_payment(DESTINATION_DOMAIN + 123, 10_u256);
}

#[test]
#[should_panic(expected: 'ERC20: insufficient allowance')]
fn test_pay_for_gas_with_insufficient_allowance() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_limit: u256 = 10_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_limit);
    let underpayment = required - 1;

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, underpayment);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    igp.pay_for_gas(77_u256, DESTINATION_DOMAIN, gas_limit);
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_set_beneficiary_only_owner() {
    let (igp, _, _) = setup_interchain_gas_paymaster();

    let new_beneficiary: ContractAddress = 'NEWBEN'.try_into().unwrap();
    igp.set_beneficiary(new_beneficiary);
}

#[test]
fn test_pay_for_gas() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_limit: u256 = 50_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_limit);

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, required);

    let mut spy = spy_events();

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    let message_id: u256 = 42;
    igp.pay_for_gas(message_id, DESTINATION_DOMAIN, gas_limit);

    let expected_payment_event = igp_mod::Event::GasPayment(
        GasPayment {
            message_id: message_id,
            destination_domain: DESTINATION_DOMAIN,
            gas_limit: gas_limit,
            payment: required,
        }
    );
    
    spy.assert_emitted(@array![(igp.contract_address, expected_payment_event)]);
    assert_eq!(fee_token.balanceOf(igp.contract_address), required);
}

#[test]
fn test_claim() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_limit: u256 = 50_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_limit);
    let total_payment = required;

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, total_payment);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    igp.pay_for_gas(1_u256, DESTINATION_DOMAIN, gas_limit);

    let claimed = igp.claim();
    assert_eq!(claimed, required);
    assert_eq!(fee_token.balanceOf(BENEFICIARY()), required);
    assert_eq!(fee_token.balanceOf(igp.contract_address), 0);
}

#[test]
fn test_claim_from_random_caller() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_limit: u256 = 50_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_limit);
    let total_payment = required;

    // Owner pays for gas
    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, total_payment);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    igp.pay_for_gas(1_u256, DESTINATION_DOMAIN, gas_limit);

    // Random address (not owner) calls claim
    let random_caller: ContractAddress = 'RANDOM_CALLER'.try_into().unwrap();
    let mut spy = spy_events();

    cheat_caller_address(
        igp.contract_address, random_caller, CheatSpan::TargetCalls(1)
    );
    let claimed = igp.claim();

    // Verify fees go to beneficiary, not the caller
    assert_eq!(claimed, required);
    assert_eq!(fee_token.balanceOf(BENEFICIARY()), required);
    assert_eq!(fee_token.balanceOf(random_caller), 0);
    assert_eq!(fee_token.balanceOf(igp.contract_address), 0);

    // Verify TokensClaimed event is emitted
    let expected_claim_event = igp_mod::Event::TokensClaimed(
        TokensClaimed {
            beneficiary: BENEFICIARY(),
            amount: required,
        }
    );
    
    spy.assert_emitted(@array![(igp.contract_address, expected_claim_event)]);
}
