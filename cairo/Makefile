# Makefile for Hyperlane Starknet Cairo

.PHONY: build clean rebuild help

# Default target
help:
	@echo "Available targets:"
	@echo "  build [FEE_TOKEN_ADDRESS] - Build project, optionally setting fee token first"
	@echo "  clean                     - Clean the project with scarb"
	@echo "  rebuild [FEE_TOKEN_ADDRESS] - Clean and build, optionally setting fee token"
	@echo ""
	@echo "Examples:"
	@echo "  make build                                    # Build with current fee token"
	@echo "  make build 0x1234567890abcdef...             # Set fee token and build"
	@echo "  make rebuild 0x1234567890abcdef...           # Set fee token, clean and build"

# Build the project (with optional fee token address as first argument)
build:
ifneq ($(word 2,$(MAKECMDGOALS)),)
	@echo "Cleaning project before fee token update..."
	scarb clean
	@echo "Updating fee token to $(word 2,$(MAKECMDGOALS))..."
	./feeToken $(word 2,$(MAKECMDGOALS))
endif
	@echo "Building project..."
	scarb build

# Clean the project
clean:
	@echo "Cleaning project..."
	scarb clean

# Clean and build (with optional fee token address)
rebuild:
	@echo "Cleaning project..."
	scarb clean
ifneq ($(word 2,$(MAKECMDGOALS)),)
	@echo "Updating fee token to $(word 2,$(MAKECMDGOALS))..."
	./feeToken $(word 2,$(MAKECMDGOALS))
endif
	@echo "Building project..."
	scarb build

# Prevent make from treating the address argument as a target
%:
	@: