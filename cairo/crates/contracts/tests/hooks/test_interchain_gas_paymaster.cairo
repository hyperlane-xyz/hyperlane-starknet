use contracts::hooks::interchain_gas_paymaster::interchain_gas_paymaster as igp_mod;
use igp_mod::{GasPayment, GasRefund};
use contracts::interfaces::{
    IInterchainGasPaymasterDispatcherTrait, IPostDispatchHookDispatcherTrait, Types
};
use alexandria_bytes::{Bytes, BytesTrait};
use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{CheatSpan, EventSpyAssertionsTrait, cheat_caller_address, spy_events};
use starknet::{ContractAddress, contract_address_const};
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
    let gas_amount: u256 = 50_000;

    let overhead: u256 = 1_000;
    let gas_price: u256 = 1_000;
    let expected: u256 = (gas_amount + overhead) * gas_price;

    assert_eq!(igp.quote_gas_payment(DESTINATION_DOMAIN, gas_amount), expected);
}

#[test]
#[should_panic(expected: 'IGP: conf not found for domain')]
fn test_quote_gas_payment_fails_without_config() {
    let (igp, _, _) = setup_interchain_gas_paymaster();
    igp.quote_gas_payment(DESTINATION_DOMAIN + 123, 10_u256);
}

#[test]
#[should_panic(expected: 'IGP: insufficient payment')]
fn test_pay_for_gas_with_insufficient_payment() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_amount: u256 = 10_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_amount);
    let underpayment = required - 1;

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, underpayment);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    let refund_addr: ContractAddress = 'R'.try_into().unwrap();
    igp.pay_for_gas(77_u256, DESTINATION_DOMAIN, gas_amount, underpayment, refund_addr);
}

#[test]
#[should_panic(expected: 'IGP: zero refund address')]
fn test_pay_for_gas_with_zero_refund_address() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_amount: u256 = 10_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_amount);

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, required);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );

    igp
        .pay_for_gas(
            1_u256, DESTINATION_DOMAIN, gas_amount, required, contract_address_const::<0>()
        );
}

#[test]
#[should_panic(expected: 'IGP: not beneficiary')]
fn test_claim_fails_if_not_beneficiary() {
    let (igp, _, _) = setup_interchain_gas_paymaster();

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    igp.claim();
}

#[test]
#[should_panic(expected: 'Caller is not the owner')]
fn test_set_beneficiary_only_owner() {
    let (igp, _, _) = setup_interchain_gas_paymaster();

    let new_beneficiary: ContractAddress = 'NEWBEN'.try_into().unwrap();
    igp.set_beneficiary(new_beneficiary);
}

#[test]
fn test_pay_for_gas_and_refund() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_amount: u256 = 50_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_amount);
    let extra: u256 = 1_000;
    let total_payment = required + extra;

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, total_payment);

    let mut spy = spy_events();

    let refund_address: ContractAddress = 'REFUND_ADDR'.try_into().unwrap();

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    let message_id: u256 = 42;
    igp.pay_for_gas(message_id, DESTINATION_DOMAIN, gas_amount, total_payment, refund_address);

    let expected_payment_event = igp_mod::Event::GasPayment(
        GasPayment {
            message_id: message_id,
            destination_domain: DESTINATION_DOMAIN,
            gas_amount: gas_amount,
            payment: required,
        }
    );
    let expected_refund_event = igp_mod::Event::GasRefund(
        GasRefund { refund_address: refund_address, amount: extra, }
    );
    spy
        .assert_emitted(
            @array![
                (igp.contract_address, expected_payment_event),
                (igp.contract_address, expected_refund_event),
            ]
        );

    assert_eq!(fee_token.balanceOf(refund_address), extra);
    assert_eq!(fee_token.balanceOf(igp.contract_address), required);
}

#[test]
fn test_claim() {
    let (igp, _, fee_token) = setup_interchain_gas_paymaster();
    let gas_amount: u256 = 50_000;
    let required = igp.quote_gas_payment(DESTINATION_DOMAIN, gas_amount);
    let total_payment = required;

    cheat_caller_address(
        fee_token.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    fee_token.approve(igp.contract_address, total_payment);

    cheat_caller_address(
        igp.contract_address, OWNER().try_into().unwrap(), CheatSpan::TargetCalls(1)
    );
    igp.pay_for_gas(1_u256, DESTINATION_DOMAIN, gas_amount, total_payment, BENEFICIARY());

    cheat_caller_address(igp.contract_address, BENEFICIARY(), CheatSpan::TargetCalls(1));
    let claimed = igp.claim();
    assert_eq!(claimed, required);
    assert_eq!(fee_token.balanceOf(BENEFICIARY()), required);
    assert_eq!(fee_token.balanceOf(igp.contract_address), 0);
}
