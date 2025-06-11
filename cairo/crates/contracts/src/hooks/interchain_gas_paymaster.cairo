#[starknet::contract]
pub mod interchain_gas_paymaster {
    // IMPORTS
    use alexandria_bytes::{Bytes, BytesTrait};
    use contracts::hooks::libs::standard_hook_metadata::standard_hook_metadata::{
        StandardHookMetadata, VARIANT,
    };
    use contracts::interfaces::{IInterchainGasPaymaster, IPostDispatchHook, Types};
    use contracts::libs::message::{Message, MessageTrait};
    use core::array::ArrayTrait;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{
        ContractAddress, contract_address_const, get_caller_address, get_contract_address,
    };

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
        /// Token address used for gas payments
        fee_token: ContractAddress,
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
        pub gas_limit: u256,
        pub payment: u256,
    }

    #[derive(starknet::Event, Drop)]
    pub struct TokensClaimed {
        pub beneficiary: ContractAddress,
        pub amount: u256,
    }

    // ERRORS
    pub mod Errors {
        pub const CONFIG_NOT_FOUND: felt252 = 'IGP: conf not found for domain';
        pub const INVALID_METADATA: felt252 = 'IGP: invalid metadata';
        pub const ZERO_BENEFICARY: felt252 = 'IGP: zero beneficiary';
    }

    // CONSTRUCTOR
    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        beneficiary: ContractAddress,
        token_address: ContractAddress,
    ) {
        self.ownable.initializer(owner);
        self._set_beneficiary(beneficiary);
        self.fee_token.write(token_address);
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
            _metadata.size() == 0
                || StandardHookMetadata::variant(_metadata.clone()) == VARIANT.into()
        }

        /// Post action after a message is dispatched via the Mailbox
        ///
        /// # Arguments
        ///
        /// * `_metadata` - the metadata required for the hook
        /// * `_message` - the message passed from the Mailbox.dispatch() call
        /// * `_fee_amount` - the payment provided for sending the message
        fn post_dispatch(
            ref self: ContractState, _metadata: Bytes, _message: Message, _fee_amount: u256,
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

            let gas_limit: u256 = StandardHookMetadata::gas_limit(
                _metadata.clone(), DEFAULT_GAS_USAGE,
            );
            let destination_domain = _message.destination;
            self.quote_gas_payment(destination_domain, gas_limit)
        }
    }

    // IInterchainGasPaymaster IMPLEMENTATION
    #[abi(embed_v0)]
    impl IInterchainGasPaymasterImpl of IInterchainGasPaymaster<ContractState> {
        /// Pays fee token for gas.
        ///
        /// # Arguments
        ///
        /// * `_message_id` - ID of the message to pay for
        /// * `_destination_domain` - Domain ID of the destination chain
        /// * `_gas_limit` - Gas limit to pay for on the destination chain
        fn pay_for_gas(
            ref self: ContractState, _message_id: u256, _destination_domain: u32, _gas_limit: u256,
        ) {
            let required = self.quote_gas_payment(_destination_domain, _gas_limit);

            let caller = get_caller_address();
            let gas_token = ERC20ABIDispatcher { contract_address: self.fee_token.read() };
            gas_token.transfer_from(caller, get_contract_address(), required);

            self
                .emit(
                    GasPayment {
                        message_id: _message_id,
                        destination_domain: _destination_domain,
                        gas_limit: _gas_limit,
                        payment: required,
                    },
                );
        }

        /// Quotes gas payment amount for a given destination domain and gas limit.
        ///
        /// # Arguments
        ///
        /// * `_destination_domain` - Domain ID of the destination chain
        /// * `_gas_limit` - Gas limit to quote for on the destination chain
        ///
        /// # Returns
        ///
        /// u256 - Total required payment in native tokens
        fn quote_gas_payment(
            ref self: ContractState, _destination_domain: u32, _gas_limit: u256,
        ) -> u256 {
            let config = self.gas_configs.read(_destination_domain);

            let dest_cost: u256 = _gas_limit * config.gas_price.into();
            (dest_cost * config.token_exchange_rate.into()) / TOKEN_EXCHANGE_RATE_SCALE
        }

        /// Sets gas configuration for multiple destination domains.
        ///
        /// # Arguments
        ///
        /// * `configs` - Array of GasParam configurations to set
        fn set_destination_gas_configs(ref self: ContractState, configs: Array<GasParam>) {
            self.ownable.assert_only_owner();
            for config in configs {
                self._set_destination_gas_config(config.remote_domain, config.config);
            }
        }

        /// Sets the beneficiary address that can withdraw collected payments.
        ///
        /// # Arguments
        ///
        /// * `beneficiary` - New beneficiary address
        fn set_beneficiary(ref self: ContractState, beneficiary: ContractAddress) {
            self.ownable.assert_only_owner();
            self._set_beneficiary(beneficiary)
        }

        /// Claim all collected fee tokens.
        ///
        /// # Returns
        ///
        /// u256 - Amount claimed
        fn claim(ref self: ContractState) -> u256 {
            let beneficiary = self.beneficiary.read();

            let gas_token = ERC20ABIDispatcher { contract_address: self.fee_token.read() };
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
        fn get_gas_config(self: @ContractState, _destination_domain: u32) -> GasConfig {
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
            ref self: ContractState, _metadata: Bytes, _message: Message, _fee_amount: u256,
        ) {
            let config = self.gas_configs.read(_message.destination);
            let (message_id, _) = MessageTrait::format_message(_message.clone());

            let gas_limit_for_destination: u256 = StandardHookMetadata::gas_limit(
                _metadata.clone(), DEFAULT_GAS_USAGE,
            )
                + config.gas_overhead.into();

            self.pay_for_gas(message_id, _message.destination, gas_limit_for_destination);
        }

        /// Sets gas configuration for a destination domain.
        ///
        /// # Arguments
        ///
        /// * `_remote_domain` - Domain ID of the destination chain
        /// * `_config` - Gas configuration to set
        fn _set_destination_gas_config(
            ref self: ContractState, _remote_domain: u32, _config: GasConfig,
        ) {
            assert(_config.token_exchange_rate != 0, Errors::CONFIG_NOT_FOUND);

            self.gas_configs.write(_remote_domain, _config);
            self
                .emit(
                    DestinationGasConfigSet {
                        remote_domain: _remote_domain,
                        token_exchange_rate: _config.token_exchange_rate,
                        gas_price: _config.gas_price,
                        gas_overhead: _config.gas_overhead,
                    },
                );
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
}
