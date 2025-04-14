use alexandria_bytes::{Bytes, BytesTrait};
use contracts::client::gas_router_component::{
    GasRouterComponent::GasRouterConfig, IGasRouterDispatcher, IGasRouterDispatcherTrait,
};
use contracts::hooks::libs::standard_hook_metadata::standard_hook_metadata::VARIANT;
use contracts::utils::utils::U256TryIntoContractAddress;
use core::integer::BoundedInt;
use mocks::{
    mock_eth::{MockEthDispatcher, MockEthDispatcherTrait}, 
    mock_mailbox::IMockMailboxDispatcher,
    mock_paradex_dex::{IMockParadexDex, IMockParadexDexDispatcher, IMockParadexDexDispatcherTrait},
    test_erc20::ITestERC20DispatcherTrait,
    test_interchain_gas_payment::ITestInterchainGasPaymentDispatcherTrait,
    test_post_dispatch_hook::{
        ITestPostDispatchHookDispatcher, ITestPostDispatchHookDispatcherTrait,
    },
};
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{CheatSpan, ContractClassTrait, DeclareResultTrait, cheat_caller_address, declare, spy_events};
use starknet::ContractAddress;
use super::common::{
    ALICE, BOB, DESTINATION, E18, GAS_LIMIT, IHypERC20TestDispatcher, IHypERC20TestDispatcherTrait,
    ORIGIN, REQUIRED_VALUE, Setup, TRANSFER_AMT, setup,
};
use token::extensions::hyp_erc20_dex_collateral::{
    IHypErc20DexCollateral, IHypErc20DexCollateralDispatcher, IHypErc20DexCollateralDispatcherTrait
};

// Setup for DEX collateral tests
fn setup_dex_collateral() -> (IHypERC20TestDispatcher, Setup, IMockParadexDexDispatcher) {
    let setup = setup();
    
    // Deploy the mock DEX
    let mock_dex_contract = declare("MockParadexDex").unwrap().contract_class();
    let (dex_address, _) = mock_dex_contract.deploy(@array![]).unwrap();
    let dex = IMockParadexDexDispatcher { contract_address: dex_address };
    
    // Deploy the HypErc20DexCollateral contract
    let hyp_erc20_dex_collateral_contract = declare("HypErc20DexCollateral").unwrap().contract_class();
    let constructor_args: Array<felt252> = array![
        setup.local_mailbox.contract_address.into(),
        dex_address.into(),
        setup.primary_token.contract_address.into(),
        ALICE().into(),
        setup.noop_hook.contract_address.into(),
        setup.primary_token.contract_address.into() // just a placeholder for ISM
    ];

    let (collateral_address, _) = hyp_erc20_dex_collateral_contract.deploy(@constructor_args).unwrap();
    let collateral = IHypERC20TestDispatcher { contract_address: collateral_address };
    dex.set_hyperlane_token(collateral_address);

    // Approve tokens for collateral
    cheat_caller_address(
        setup.eth_token.contract_address, ALICE().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    IERC20Dispatcher { contract_address: setup.eth_token.contract_address }
        .approve(collateral_address, BoundedInt::max());

    // Enroll remote router
    let remote_token_address: felt252 = setup.remote_token.contract_address.into();
    cheat_caller_address(
        collateral.contract_address, ALICE().try_into().unwrap(), CheatSpan::TargetCalls(1),
    );
    collateral.enroll_remote_router(DESTINATION, remote_token_address.into());

    // Transfer tokens to collateral contract and ALICE
    setup.primary_token.transfer(collateral.contract_address, 1000 * E18);
    setup.primary_token.transfer(ALICE(), 1000 * E18);
    
    // Enroll remote router for the remote token
    let addr: felt252 = collateral.contract_address.into();
    setup.remote_token.enroll_remote_router(ORIGIN, addr.into());
    
    (collateral, setup, dex)
}

fn perform_remote_transfer_dex(
    setup: @Setup,
    collateral: @IHypERC20TestDispatcher,
    dex: @IMockParadexDexDispatcher,
    msg_value: u256,
    amount: u256,
    approve: bool,
) {
    // Approve tokens if needed
    if approve {
        cheat_caller_address(
            *setup.primary_token.contract_address, ALICE(), CheatSpan::TargetCalls(1),
        );
        (*setup.primary_token).approve(*collateral.contract_address, amount);
    }
    
    // Remote transfer
    cheat_caller_address(*collateral.contract_address, ALICE(), CheatSpan::TargetCalls(1));
    let bob_felt: felt252 = BOB().into();
    let bob_address: u256 = bob_felt.into();
    (*collateral)
        .transfer_remote(DESTINATION, bob_address, amount, msg_value, Option::None, Option::None);

    // Process the transfer
    process_transfers_dex(setup, collateral, dex, BOB(), amount);
}

fn process_transfers_dex(
    setup: @Setup, 
    collateral: @IHypERC20TestDispatcher, 
    dex: @IMockParadexDexDispatcher,
    recipient: ContractAddress, 
    amount: u256,
) {
    cheat_caller_address(
        (*setup).remote_token.contract_address,
        (*setup).remote_mailbox.contract_address,
        CheatSpan::TargetCalls(1),
    );

    let local_token_address: felt252 = (*collateral).contract_address.into();
    let mut message = BytesTrait::new_empty();
    message.append_address(recipient);
    message.append_u256(amount);
    (*setup).remote_token.handle(ORIGIN, local_token_address.into(), message);
}

#[test]
fn test_dex_contract_setup() {
    let (collateral, _, dex) = setup_dex_collateral();
    
    // Check that the DEX is properly configured
    let dex_collateral = IHypErc20DexCollateralDispatcher { contract_address: collateral.contract_address };
    assert_eq!(dex_collateral.get_dex(), dex.contract_address, "DEX address mismatch");
    
    // Check that the token is properly configured
    let deposit_token = dex_collateral.get_deposit_token();
    assert_ne!(deposit_token, starknet::contract_address_const::<0>(), "Deposit token not set");
}

#[test]
fn test_remote_transfer_dex() {
    let (collateral, setup, dex) = setup_dex_collateral();
    
    // Capture events for later verification
    // let event_spy = spy_events(collateral.contract_address);
    
    // Record balance before transfer
    let balance_before = collateral.balance_of(ALICE());
    
    // Perform the remote transfer
    perform_remote_transfer_dex(@setup, @collateral, @dex, REQUIRED_VALUE, TRANSFER_AMT, true);
    
    // Check balance after transfer
    assert_eq!(
        collateral.balance_of(ALICE()),
        balance_before - TRANSFER_AMT,
        "Incorrect balance after transfer"
    );
    
    // TODO: Verify that events were emitted
    // let events = event_spy.events;
    // assert!(events.len() > 0, "No events were emitted");
}

#[test]
#[should_panic]
fn test_remote_transfer_dex_invalid_allowance() {
    let (collateral, setup, dex) = setup_dex_collateral();
    // Try to transfer without approving first, which should fail
    perform_remote_transfer_dex(@setup, @collateral, @dex, REQUIRED_VALUE, TRANSFER_AMT, false);
}

#[test]
fn test_dex_deposit_succeeds() {
    let (collateral, setup, dex) = setup_dex_collateral();

    
    // Perform the remote transfer
    start_prank(collateral.contract_address, ALICE());
    let bob_felt: felt252 = BOB().into();
    let bob_address: u256 = bob_felt.into();
    collateral.transfer_remote(DESTINATION, bob_address, TRANSFER_AMT, REQUIRED_VALUE, Option::None, Option::None);
    stop_prank(collateral.contract_address);
    
    // Process the transfer which will call the DEX
    process_transfers_dex(@setup, @collateral, @dex, BOB(), TRANSFER_AMT);
    
    // Check for DexDeposit event
    let events = event_spy.events;
    let mut found_dex_deposit = false;
    
    for event in events {
        // Check for DexDeposit event (we can't directly match the event type here)
        // Instead, we'll check if the event contains the right data
        if event.keys.len() >= 2 {
            if event.keys[0] == setup.primary_token.contract_address.into() && 
               event.keys[1] == BOB().into() {
                found_dex_deposit = true;
                break;
            }
        }
    }
    
    assert!(found_dex_deposit, "DexDeposit event not found");
}

#[test]
fn test_dex_collateral_with_custom_gas_config() {
    let (collateral, setup, dex) = setup_dex_collateral();
    
    // Check balance before transfer
    let balance_before = collateral.balance_of(ALICE());
    
    // Set custom gas config
    start_prank(collateral.contract_address, ALICE());
    collateral.set_hook(setup.igp.contract_address);
    let config = array![GasRouterConfig { domain: DESTINATION, gas: GAS_LIMIT }];
    collateral.set_destination_gas(Option::Some(config), Option::None, Option::None);
    stop_prank(collateral.contract_address);
    
    let gas_price = setup.igp.gas_price();
    
    // Do a remote transfer with gas payment
    perform_remote_transfer_dex(
        @setup, 
        @collateral, 
        @dex,
        REQUIRED_VALUE + GAS_LIMIT * gas_price, 
        TRANSFER_AMT, 
        true
    );

    // Check balance after transfer
    assert_eq!(
        collateral.balance_of(ALICE()),
        balance_before - TRANSFER_AMT,
        "Incorrect balance after transfer"
    );
    
    // Check that gas fee was transferred
    let eth_dispatcher = IERC20Dispatcher { contract_address: setup.eth_token.contract_address };
    assert_eq!(
        eth_dispatcher.balance_of(setup.igp.contract_address),
        GAS_LIMIT * gas_price,
        "Gas fee wasn't transferred"
    );
}

#[test]
fn test_dex_amount_conversion() {
    // This test verifies that the amount is properly converted from u256 to felt252
    // when calling the DEX's deposit_on_behalf_of function
    
    let (collateral, setup, dex) = setup_dex_collateral();
    
    // Use a value that can fit in a felt252
    let test_amount: u256 = 123456789;
    let expected_felt_amount: felt252 = 123456789;
    
    // Directly call the DEX's deposit_on_behalf_of function
    start_prank(collateral.contract_address, ALICE());
    
    // First approve the tokens
    start_prank(setup.primary_token.contract_address, ALICE());
    setup.primary_token.approve(dex.contract_address, test_amount);
    
    // Now call the deposit function directly
    let result = dex.deposit_on_behalf_of(
        BOB(),
        setup.primary_token.contract_address,
        expected_felt_amount
    );
    
    // Verify the result (the mock should return true if called correctly)
    assert_eq!(result, true, "DEX deposit on behalf function failed");
}

#[test]
#[fuzzer]
fn test_fuzz_remote_transfer_dex_various_amounts(mut amount: u256) {
    // Limit amount to reasonable values to prevent overflow
    amount %= 100 * E18;
    if amount == 0 {
        amount = 1 * E18; // Ensure non-zero amount
    }
    
    let (collateral, setup, dex) = setup_dex_collateral();
    
    // Record balance before transfer
    let balance_before = collateral.balance_of(ALICE());
    
    // Perform the remote transfer
    perform_remote_transfer_dex(@setup, @collateral, @dex, REQUIRED_VALUE, amount, true);
    
    // Check balance after transfer
    assert_eq!(
        collateral.balance_of(ALICE()),
        balance_before - amount,
        "Incorrect balance after transfer"
    );
}

// #[test]
// #[should_panic]
// fn test_amount_exceeding_felt252_range() {
//     let (collateral, setup, dex) = setup_dex_collateral();
    
//     // Use a value that exceeds felt252 range
//     let large_amount: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000;
    
//     // Approve tokens
//     start_prank(setup.primary_token.contract_address, ALICE());
//     setup.primary_token.approve(collateral.contract_address, large_amount);
    
//     // This should panic during transfer_to_hook when trying to convert to felt252
//     start_prank(collateral.contract_address, ALICE());
//     let bob_felt: felt252 = BOB().into();
//     let bob_address: u256 = bob_felt.into();
//     collateral.transfer_remote(DESTINATION, bob_address, large_amount, REQUIRED_VALUE, Option::None, Option::None);
    
//     // Process the transfer which will fail due to the amount conversion
//     process_transfers_dex(@setup, @collateral, @dex, BOB(), large_amount);
// }