use core::num::traits::Pow;
use starknet::ContractAddress;

pub impl U256TryIntoContractAddress of TryInto<u256, ContractAddress> {
    fn try_into(self: u256) -> Option<ContractAddress> {
        let maybe_value: Option<felt252> = self.try_into();
        match maybe_value {
            Option::Some(value) => value.try_into(),
            Option::None => Option::None,
        }
    }
}

pub fn scale_amount(amount: u256, source_decimals: u8, target_decimals: u8) -> u256 {
    if source_decimals > target_decimals {
        amount / (10_u256.pow((source_decimals - target_decimals).into()))
    } else if source_decimals < target_decimals {
        amount * (10_u256.pow((target_decimals - source_decimals).into()))
    } else {
        amount
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scale_amount_down() {
        let amount = 1000 * 10_u256.pow(18);
        let source_decimals = 18;
        let target_decimals = 6;
        let expected = 1000 * 10_u256.pow(6);
        assert(
            scale_amount(amount, source_decimals, target_decimals) == expected, 'scale down failed',
        );
    }

    #[test]
    fn test_scale_amount_up() {
        let amount = 1000 * 10_u256.pow(6);
        let source_decimals = 6;
        let target_decimals = 18;
        let expected = 1000 * 10_u256.pow(18);
        assert(
            scale_amount(amount, source_decimals, target_decimals) == expected, 'scale up failed',
        );
    }

    #[test]
    fn test_scale_amount_same_decimals() {
        let amount = 1000 * 10_u256.pow(18);
        let source_decimals = 18;
        let target_decimals = 18;
        assert(
            scale_amount(amount, source_decimals, target_decimals) == amount,
            'same decimals failed',
        );
    }

    #[test]
    fn test_scale_amount_zero() {
        let amount = 0;
        let source_decimals = 18;
        let target_decimals = 6;
        assert(scale_amount(amount, source_decimals, target_decimals) == 0, 'zero amount failed');
    }
}

