// SPDX-License-Identifier: MIT OR Apache-2.0

#[starknet::contract]
pub mod interchain_gas_paymaster {
    // IMPORTS
    use core::array::ArrayTrait;
    use alexandria_bytes::{Bytes, BytesTrait};
    use contracts::interfaces::{
        ETH_ADDRESS, IInterchainGasPaymaster,
        IPostDispatchHook, Types,
    };
    use contracts::hooks::libs::standard_hook_metadata::standard_hook_metadata::{
        StandardHookMetadata, VARIANT,
    };
    use contracts::libs::message::{Message, MessageTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_caller_address, contract_address_const, get_contract_address};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;
    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    /// Scale factor used to convert between exchange rates (1e10 in solidity).
    pub const TOKEN_EXCHANGE_RATE_SCALE: u256 = 10_000_000_000;

    /// Default gas usage when metadata gasLimit is not provided.
    pub const DEFAULT_GAS_USAGE: u256 = 50_000;


    #[derive(Drop, Serde, Copy, Clone, starknet::Store)]
    pub struct GasConfig {
        pub token_exchange_rate: u128,
        pub gas_price: u128,
        pub gas_overhead: u256,
    }

    #[derive(Drop, Serde)]
    pub struct GasParam {
        pub remote_domain: u32,
        pub config: GasConfig,
    }


    // STORAGE
    #[storage]
    struct Storage {
        /// Mapping: destination domain => GasConfig
        gas_configs: Map<u32, GasConfig>,
        /// Beneficiary that can withdraw collected payments
        beneficiary: ContractAddress,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    // EVENTS
    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        DestinationGasConfigSet: DestinationGasConfigSet,
        BeneficiarySet: BeneficiarySet,
        GasPayment: GasPayment,
        GasRefund: GasRefund,
        TokensClaimed: TokensClaimed,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(starknet::Event, Drop)]
    pub struct DestinationGasConfigSet {
        pub remote_domain: u32,
        pub token_exchange_rate: u128,
        pub gas_price: u128,
        pub gas_overhead: u256,
    }

    #[derive(starknet::Event, Drop)]
    pub struct BeneficiarySet {
        pub beneficiary: ContractAddress,
    }

    #[derive(starknet::Event, Drop)]
    pub struct GasPayment {
        pub message_id: u256,
        pub destination_domain: u32,
        pub gas_amount: u256,
        pub payment: u256,
    }

    #[derive(starknet::Event, Drop)]
    pub struct GasRefund {
        pub refund_address: ContractAddress,
        pub amount: u256,
    }

    #[derive(starknet::Event, Drop)]
    pub struct TokensClaimed {
        pub beneficiary: ContractAddress,
        pub amount: u256,
    }

    // ERRORS
    pub mod Errors {
        pub const INSUFFICIENT_PAYMENT: felt252 = 'IGP: insufficient payment';
        pub const CONFIG_NOT_FOUND: felt252 = 'IGP: conf not found for domain';
        pub const INVALID_METADATA: felt252 = 'IGP: invalid metadata';
        pub const ZERO_BENEFICARY: felt252 = 'IGP: zero beneficiary';
        pub const ZERO_REFUND_ADDRESS: felt252 = 'IGP: zero refund address';
        pub const REFUND_FAILED: felt252 = 'IGP: refund failed';
        pub const NOT_BENEFICIARY: felt252 = 'IGP: not beneficiary';
        pub const TRANSFER_FAILED: felt252 = 'IGP: transfer failed';
    }

    // CONSTRUCTOR
    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, beneficiary: ContractAddress) {
        self.ownable.initializer(owner);
        self._set_beneficiary(beneficiary);
    }

    // IPostDispatchHook IMPLEMENTATION
    #[abi(embed_v0)]
    impl IPostDispatchHookImpl of IPostDispatchHook<ContractState> {
        fn hook_type(self: @ContractState) -> Types {
            Types::INTERCHAIN_GAS_PAYMASTER(())
        }

        /// Returns `true` if metadata is empty or formatted as StandardHookMetadata.
        ///
        /// # Arguments
        ///
        /// * `_metadata` - metadata bytes to check
        ///
        /// # Returns
        ///
        /// Whether the hook supports the given metadata format
        fn supports_metadata(self: @ContractState, _metadata: Bytes) -> bool {
            _metadata.size() == 0 || StandardHookMetadata::variant(_metadata.clone()) == VARIANT.into()
        }

        /// Post action after a message is dispatched via the Mailbox
        ///
        /// # Arguments
        ///
        /// * `_metadata` - the metadata required for the hook
        /// * `_message` - the message passed from the Mailbox.dispatch() call
        /// * `_fee_amount` - the payment provided for sending the message
        fn post_dispatch(
            ref self: ContractState,
            _metadata: Bytes,
            _message: Message,
            _fee_amount: u256,
        ) {
            assert(self.supports_metadata(_metadata.clone()), Errors::INVALID_METADATA);
            self._post_dispatch(_metadata, _message, _fee_amount);
        }

        /// Quotes the payment required given metadata & message.
        ///
        /// # Arguments
        ///
        /// * `_metadata` - the metadata required for the hook
        /// * `_message` - the message passed from the Mailbox.dispatch() call
        ///
        /// # Returns
        ///
        /// u256 - Quoted payment for the postDispatch call
        fn quote_dispatch(ref self: ContractState, _metadata: Bytes, _message: Message) -> u256 {
            assert(self.supports_metadata(_metadata.clone()), Errors::INVALID_METADATA);

            let gas_limit: u256 = match _metadata.size() {
                0 => DEFAULT_GAS_USAGE,
                _ => {
                    assert(
                        StandardHookMetadata::variant(_metadata.clone()) == VARIANT.into(),
                        Errors::INVALID_METADATA,
                    );
                    StandardHookMetadata::gas_limit(_metadata, DEFAULT_GAS_USAGE)
                },
            };
            let destination_domain = _message.destination;
            self.quote_gas_payment(destination_domain, gas_limit)
        }
    }

    // IInterchainGasPaymaster IMPLEMENTATION
    #[abi(embed_v0)]
    impl IInterchainGasPaymasterImpl of IInterchainGasPaymaster<ContractState> {
        /// Pays `payment` native tokens (ERC20 ETH token) for gas.
        ///
        /// # Arguments
        ///
        /// * `_message_id` - ID of the message to pay for
        /// * `_destination_domain` - Domain ID of the destination chain
        /// * `_gas_amount` - Amount of gas to pay for on the destination chain
        /// * `_payment` - Amount of native tokens to pay
        /// * `_refund_address` - Address to refund any overpayment
        fn pay_for_gas(
            ref self: ContractState,
            _message_id: u256,
            _destination_domain: u32,
            _gas_amount: u256,
            _payment: u256,
            _refund_address: ContractAddress,
        ) {
            assert(_refund_address != contract_address_const::<0>(), Errors::ZERO_REFUND_ADDRESS);

            let required = self.quote_gas_payment(_destination_domain, _gas_amount);
            assert(_payment >= required, Errors::INSUFFICIENT_PAYMENT);

            let caller = get_caller_address();
            let gas_token = ERC20ABIDispatcher { contract_address: ETH_ADDRESS() };
            gas_token.transfer_from(caller, get_contract_address(), _payment);

            let refund_amount = _payment - required;
            if refund_amount > 0 {
                gas_token.transfer( _refund_address, refund_amount);
                self.emit(GasRefund { refund_address: _refund_address, amount: refund_amount });
            }

            self.emit(GasPayment { message_id: _message_id, destination_domain: _destination_domain, gas_amount: _gas_amount, payment: required });
        }

        /// Quotes gas payment amount for a given destination domain and gas amount.
        ///
        /// # Arguments
        ///
        /// * `_destination_domain` - Domain ID of the destination chain
        /// * `_gas_amount` - Amount of gas to quote for on the destination chain
        ///
        /// # Returns
        ///
        /// u256 - Total required payment in native tokens
        fn quote_gas_payment(
            ref self: ContractState,
            _destination_domain: u32,
            _gas_amount: u256,
        ) -> u256 {
            let config = self.gas_configs.read(_destination_domain);
            assert(config.token_exchange_rate != 0, Errors::CONFIG_NOT_FOUND);
            let total_gas: u256 = _gas_amount + config.gas_overhead;
            let dest_cost: u256 = total_gas * config.gas_price.into();
            (dest_cost * config.token_exchange_rate.into()) / TOKEN_EXCHANGE_RATE_SCALE
        }

        /// Sets gas configuration for multiple destination domains.
        ///
        /// # Arguments
        ///
        /// * `configs` - Array of GasParam configurations to set
        fn set_destination_gas_configs(
            ref self: ContractState,
            configs: Array<GasParam>
        ){
            self.ownable.assert_only_owner();
            for config in configs{
                self._set_destination_gas_config(config.remote_domain, config.config);
            }
        }

        /// Sets the beneficiary address that can withdraw collected payments.
        ///
        /// # Arguments
        ///
        /// * `beneficiary` - New beneficiary address
        fn set_beneficiary(
            ref self: ContractState,
            beneficiary: ContractAddress
        ) {
            self.ownable.assert_only_owner();
            self._set_beneficiary(beneficiary)
        }

        /// Allows the beneficiary to claim all collected ETH tokens.
        ///
        /// # Returns
        ///
        /// u256 - Amount claimed
        fn claim(ref self: ContractState) -> u256 {
            let caller = get_caller_address();
            let beneficiary = self.beneficiary.read();
            
            assert(caller == beneficiary, Errors::NOT_BENEFICIARY);
            
            let gas_token = ERC20ABIDispatcher { contract_address: ETH_ADDRESS() };
            let contract_address = get_contract_address();
            let balance = gas_token.balance_of(contract_address);
            
            if balance > 0 {
                gas_token.transfer(beneficiary, balance);
                
                self.emit(TokensClaimed { beneficiary, amount: balance });
                
                return balance;
            }
            
            0_u256
        }

        /// Gets the gas configuration for a destination domain.
        ///
        /// # Arguments
        ///
        /// * `_destination_domain` - Domain ID of the destination chain
        ///
        /// # Returns
        ///
        /// GasConfig - Gas configuration for the specified domain
        fn get_gas_config(
            self: @ContractState, 
            _destination_domain: u32
        ) -> GasConfig {
            self.gas_configs.read(_destination_domain)
        }

        /// Gets the beneficiary address.
        ///
        /// # Returns
        ///
        /// ContractAddress - Current beneficiary address
        fn get_beneficiary(self: @ContractState) -> ContractAddress {
            self.beneficiary.read()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {

        /// Internal implementation of post_dispatch that processes interchain gas payments.
        ///
        /// # Arguments
        ///
        /// * `_metadata` - The metadata required for the hook
        /// * `_message` - The message passed from the Mailbox.dispatch() call
        /// * `_fee_amount` - The payment provided for sending the message
        fn _post_dispatch(
            ref self: ContractState, _metadata: Bytes, _message: Message, _fee_amount: u256
        ) {
            let (message_id, _) = MessageTrait::format_message(_message.clone());

            let gas_amount_for_destination: u256 = StandardHookMetadata::gas_limit(_metadata.clone(), DEFAULT_GAS_USAGE);

            let refund_address = get_caller_address();

            self.pay_for_gas(
                message_id,
                _message.destination,
                gas_amount_for_destination,
                _fee_amount,
                refund_address
            );
        }
        
        /// Sets gas configuration for a destination domain.
        ///
        /// # Arguments
        ///
        /// * `_remote_domain` - Domain ID of the destination chain
        /// * `_config` - Gas configuration to set
        fn _set_destination_gas_config(
            ref self: ContractState,
            _remote_domain: u32,
            _config: GasConfig
        ) {
            self.gas_configs.write(_remote_domain, _config);
            self.emit(DestinationGasConfigSet {
                remote_domain: _remote_domain,
                token_exchange_rate: _config.token_exchange_rate,
                gas_price: _config.gas_price,
                gas_overhead: _config.gas_overhead,
            });
        }

        /// Sets beneficiary address.
        ///
        /// # Arguments
        ///
        /// * `_beneficiary` - New beneficiary address
        fn _set_beneficiary(ref self: ContractState, _beneficiary: ContractAddress) {
            assert(_beneficiary != contract_address_const::<0>(), Errors::ZERO_BENEFICARY);
            self.beneficiary.write(_beneficiary);
            self.emit(BeneficiarySet { beneficiary: _beneficiary });
        }

    }

    // TODOs
    // The implementation above provides a complete InterchainGasPaymaster (IGP) for Starknet.
    // The following items should be addressed before production deployment:
    //
    // 1. **Unit & Integration Tests**
    //    – Add snforge tests mirroring the Solidity & Sealevel test-suites to validate
    //      `quote_gas_payment`, overflow paths, and metadata edge-cases.
    //
    // 2. **Security Audit**
    //    – Conduct a thorough security audit to ensure the contract handles edge cases
    //      correctly and is resistant to potential attacks.
}
