use alexandria_bytes::BytesTrait;
use contracts::hooks::libs::standard_hook_metadata::standard_hook_metadata::VARIANT;
use core::integer::BoundedInt;
use mocks::test_erc721::ITestERC721DispatcherTrait;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::cheatcodes::contract_class::ContractClassTrait;
use super::common::{
    DESTINATION, FEE_CAP, IHypErc721TestDispatcher, IHypErc721TestDispatcherTrait, INITIAL_SUPPLY,
    Setup, deploy_remote_token, perform_remote_transfer, setup, test_transfer_with_hook_specified,
};

fn setup_erc721_collateral() -> Setup {
    let mut setup = setup();

    let mut calldata: Array<felt252> = array![];
    setup.local_primary_token.contract_address.serialize(ref calldata);
    setup.local_mailbox.contract_address.serialize(ref calldata);
    setup.noop_hook.contract_address.serialize(ref calldata);
    setup.default_ism.serialize(ref calldata);
    starknet::get_contract_address().serialize(ref calldata);

    let (local_token, _) = setup.hyp_erc721_collateral_contract.deploy(@calldata).unwrap();
    let local_token = IHypErc721TestDispatcher { contract_address: local_token };

    setup.local_token = local_token;

    IERC20Dispatcher { contract_address: setup.eth_token.contract_address }
        .approve(local_token.contract_address, BoundedInt::max());

    let remote_token_address: felt252 = setup.remote_token.contract_address.into();
    setup.local_token.enroll_remote_router(DESTINATION, remote_token_address.into());

    setup
        .local_primary_token
        .transfer_from(
            starknet::get_contract_address(),
            setup.local_token.contract_address,
            INITIAL_SUPPLY + 1,
        );

    setup
}

#[test]
fn test_erc721_collateral_remote_transfer() {
    let mut setup = setup_erc721_collateral();

    let setup = deploy_remote_token(setup, false);
    setup.local_primary_token.approve(setup.local_token.contract_address, 0);
    perform_remote_transfer(@setup, 2500, 0);

    assert_eq!(
        setup.local_token.balance_of(starknet::get_contract_address()), INITIAL_SUPPLY * 2 - 2,
    );
}

#[test]
#[fuzzer]
fn test_fuzz_erc721__collateral_remote_transfer_with_hook_specified(mut fee: u256, metadata: u256) {
    let fee = fee % FEE_CAP;
    let mut metadata_bytes = BytesTrait::new_empty();
    metadata_bytes.append_u16(VARIANT);
    metadata_bytes.append_u256(metadata);

    let mut setup = setup_erc721_collateral();
    let setup = deploy_remote_token(setup, false);
    setup.local_primary_token.approve(setup.local_token.contract_address, 0);
    test_transfer_with_hook_specified(@setup, 0, fee, metadata_bytes);
    assert_eq!(
        setup.local_token.balance_of(starknet::get_contract_address()), INITIAL_SUPPLY * 2 - 2,
    );
}

#[test]
#[should_panic]
fn test_erc721_collateral_remote_transfer_revert_unowned() {
    let mut setup = setup_erc721_collateral();

    setup.local_primary_token.transfer_from(starknet::get_contract_address(), setup.bob, 1);

    let setup = deploy_remote_token(setup, false);
    perform_remote_transfer(@setup, 2500, 1);
}

#[test]
#[should_panic]
fn test_erc721_collateral_remote_transfer_revert_invalid_token_id() {
    let mut setup = setup_erc721_collateral();

    let setup = deploy_remote_token(setup, false);
    perform_remote_transfer(@setup, 2500, INITIAL_SUPPLY * 2);
}

