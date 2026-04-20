TAG = moonwell-contracts

ifneq (,$(wildcard .env))
include .env
export
endif

ANVIL_HOST ?= 127.0.0.1
ANVIL_MOONBEAM_PORT ?= 9545
ANVIL_BASE_PORT ?= 9546
ANVIL_OPTIMISM_PORT ?= 9547
ANVIL_ETHEREUM_PORT ?= 9548
ANVIL_START_TIMEOUT ?= 180
ANVIL_RPC_RETRIES ?= 8
ANVIL_RPC_TIMEOUT_MS ?= 120000
ANVIL_FORK_RETRY_BACKOFF_MS ?= 1500
INVARIANT_RUNS ?= 2
INVARIANT_DEPTH ?= 10

ANVIL_STATE_DIR ?= .anvil-local
ANVIL_LOG_DIR ?= $(ANVIL_STATE_DIR)/logs
ANVIL_PID_DIR ?= $(ANVIL_STATE_DIR)/pids

.PHONY: anvil-forks-up anvil-forks-down ensure-mip-artifacts test-fuzz-mint-local test-fuzz-borrow-local

build-docker:
	docker build -t $(TAG) .

# npx hardhat run --network base-localhost scripts/deploy-testnet.ts

moonbeam-node:
	docker run --rm -it -p 8545:8545 $(TAG) ganache-cli \
	    -h 0.0.0.0 \
	    --fork.url https://rpc.api.moonbeam.network \
	    --fork.blockNumber 3302234 \
	    --chain.chainId 1284 \
	    -u 0xFFA353daCD27071217EA80D3149C9d500B0e9a38 \
	    -b 1

bash:
	docker run --rm -it \
		-v $$(pwd):$$(pwd) \
		--workdir $$(pwd) \
		--net=host \
		$(TAG) \
		bash

base-testnet:
	docker run --rm -it \
		-v $$(pwd):$$(pwd) \
		--workdir $$(pwd) \
		-p 8545:8545 \
		$(TAG) \
		ganache-cli --fork https://goerli.base.org/ --host 0.0.0.0 --chain.chainId 84531 --wallet.deterministic

base:
	docker run --rm -it \
		-v $$(pwd):$$(pwd) \
		--workdir $$(pwd) \
		-p 8545:8545 \
		$(TAG) \
		ganache-cli --fork https://developer-access-mainnet.base.org --host 0.0.0.0 --chain.chainId 8453 --wallet.deterministic

# Anvil unfortunately doesn't work for deploys due to a bug in their gas estimation - https://github.com/foundry-rs/foundry/pull/2294
# anvil -f https://goerli.base.org/ --host 0.0.0.0

slither:
	docker run --rm -it \
		-v $$(pwd):$$(pwd) \
		--workdir $$(pwd) \
		$(TAG) \
	slither --solc-remaps '@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/' .

# Proxy requests to the local node, useful for debugging opaque failures
mitmproxy:
	docker run --rm -it --net=host mitmproxy/mitmproxy mitmproxy --mode reverse:http://host.docker.internal:8545@8081

coverage:
	time forge coverage --skip script \
		--out artifacts/coverage \
		--skip "Integration.t.sol" \
		--summary --report lcov \
		--match-contract UnitTest

test-unit:
	time forge test --match-contract UnitTest -vvv

# Start four local anvil fork proxies for Moonbeam/Base/Optimism/Ethereum.
# Uses current *RPC_URL env vars as upstream providers.
anvil-forks-up:
	@set -e; \
	command -v anvil >/dev/null 2>&1 || { echo "anvil not found in PATH"; exit 1; }; \
	command -v cast >/dev/null 2>&1 || { echo "cast not found in PATH"; exit 1; }; \
	for port in "$(ANVIL_MOONBEAM_PORT)" "$(ANVIL_BASE_PORT)" "$(ANVIL_OPTIMISM_PORT)" "$(ANVIL_ETHEREUM_PORT)"; do \
		for pid in $$(lsof -t -nP -iTCP:$$port -sTCP:LISTEN 2>/dev/null || true); do \
			cmdline=$$(ps -p $$pid -o args= 2>/dev/null || true); \
			case "$$cmdline" in \
				*anvil*) \
					echo "Stopping stale anvil on port $$port (pid $$pid)"; \
					kill $$pid 2>/dev/null || true; \
					;; \
				*) \
					echo "port $$port is occupied by non-anvil process (pid $$pid): $$cmdline"; \
					echo "Please free the port or change ANVIL_*_PORT in Makefile"; \
					exit 1; \
					;; \
			esac; \
		done; \
	done; \
	sleep 1; \
	: "$${MOONBEAM_RPC_URL:?MOONBEAM_RPC_URL is required}"; \
	: "$${BASE_RPC_URL:?BASE_RPC_URL is required}"; \
	: "$${OP_RPC_URL:?OP_RPC_URL is required}"; \
	: "$${ETH_RPC_URL:?ETH_RPC_URL is required}"; \
	mkdir -p "$(ANVIL_LOG_DIR)" "$(ANVIL_PID_DIR)"; \
	anvil --fork-url "$${MOONBEAM_RPC_URL}" --chain-id 1284 --host "$(ANVIL_HOST)" --port "$(ANVIL_MOONBEAM_PORT)" --retries "$(ANVIL_RPC_RETRIES)" --timeout "$(ANVIL_RPC_TIMEOUT_MS)" --fork-retry-backoff "$(ANVIL_FORK_RETRY_BACKOFF_MS)" > "$(ANVIL_LOG_DIR)/moonbeam.log" 2>&1 & echo $$! > "$(ANVIL_PID_DIR)/moonbeam.pid"; \
	anvil --fork-url "$${BASE_RPC_URL}" --chain-id 8453 --host "$(ANVIL_HOST)" --port "$(ANVIL_BASE_PORT)" --retries "$(ANVIL_RPC_RETRIES)" --timeout "$(ANVIL_RPC_TIMEOUT_MS)" --fork-retry-backoff "$(ANVIL_FORK_RETRY_BACKOFF_MS)" > "$(ANVIL_LOG_DIR)/base.log" 2>&1 & echo $$! > "$(ANVIL_PID_DIR)/base.pid"; \
	anvil --fork-url "$${OP_RPC_URL}" --chain-id 10 --host "$(ANVIL_HOST)" --port "$(ANVIL_OPTIMISM_PORT)" --retries "$(ANVIL_RPC_RETRIES)" --timeout "$(ANVIL_RPC_TIMEOUT_MS)" --fork-retry-backoff "$(ANVIL_FORK_RETRY_BACKOFF_MS)" > "$(ANVIL_LOG_DIR)/optimism.log" 2>&1 & echo $$! > "$(ANVIL_PID_DIR)/optimism.pid"; \
	anvil --fork-url "$${ETH_RPC_URL}" --chain-id 1 --host "$(ANVIL_HOST)" --port "$(ANVIL_ETHEREUM_PORT)" --retries "$(ANVIL_RPC_RETRIES)" --timeout "$(ANVIL_RPC_TIMEOUT_MS)" --fork-retry-backoff "$(ANVIL_FORK_RETRY_BACKOFF_MS)" > "$(ANVIL_LOG_DIR)/ethereum.log" 2>&1 & echo $$! > "$(ANVIL_PID_DIR)/ethereum.pid"; \
	for url in \
		"http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
		"http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
		"http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
		"http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)"; do \
		deadline=$$(( $$(date +%s) + $(ANVIL_START_TIMEOUT) )); \
		while ! cast block-number --rpc-url "$$url" >/dev/null 2>&1; do \
			if [ $$(date +%s) -ge $$deadline ]; then \
				echo "anvil endpoint not ready within $(ANVIL_START_TIMEOUT)s: $$url"; \
				case "$$url" in \
					*:$(ANVIL_MOONBEAM_PORT)) log_file="$(ANVIL_LOG_DIR)/moonbeam.log" ;; \
					*:$(ANVIL_BASE_PORT)) log_file="$(ANVIL_LOG_DIR)/base.log" ;; \
					*:$(ANVIL_OPTIMISM_PORT)) log_file="$(ANVIL_LOG_DIR)/optimism.log" ;; \
					*:$(ANVIL_ETHEREUM_PORT)) log_file="$(ANVIL_LOG_DIR)/ethereum.log" ;; \
					*) log_file="" ;; \
				esac; \
				if [ -n "$$log_file" ] && [ -f "$$log_file" ]; then \
					echo "--- tail $$log_file ---"; \
					tail -n 50 "$$log_file"; \
				fi; \
				$(MAKE) anvil-forks-down; \
				exit 1; \
			fi; \
			sleep 1; \
		done; \
		if ! cast block-number --rpc-url "$$url" >/dev/null 2>&1; then \
			echo "anvil endpoint not ready: $$url"; \
			$(MAKE) anvil-forks-down; \
			exit 1; \
		fi; \
	done; \
	echo "Local anvil forks started. Logs: $(ANVIL_LOG_DIR)"

anvil-forks-down:
	@set -e; \
	for name in moonbeam base optimism ethereum; do \
		pid_file="$(ANVIL_PID_DIR)/$$name.pid"; \
		if [ -f "$$pid_file" ]; then \
			pid=$$(cat "$$pid_file"); \
			if kill -0 "$$pid" 2>/dev/null; then kill "$$pid"; fi; \
			rm -f "$$pid_file"; \
		fi; \
	done; \
	for port in "$(ANVIL_MOONBEAM_PORT)" "$(ANVIL_BASE_PORT)" "$(ANVIL_OPTIMISM_PORT)" "$(ANVIL_ETHEREUM_PORT)"; do \
		for pid in $$(lsof -t -nP -iTCP:$$port -sTCP:LISTEN 2>/dev/null || true); do \
			cmdline=$$(ps -p $$pid -o args= 2>/dev/null || true); \
			case "$$cmdline" in \
				*anvil*) kill $$pid 2>/dev/null || true ;; \
				*) ;; \
			esac; \
		done; \
	done; \
	echo "Local anvil forks stopped."

ensure-mip-artifacts:
	@set -e; \
	if [ ! -f "artifacts/foundry/mip-b58.sol/mipb58.json" ]; then \
		echo "Generating missing artifact: artifacts/foundry/mip-b58.sol/mipb58.json"; \
		forge build --contracts proposals/mips/mip-b58/mip-b58.sol; \
	fi

test-fuzz-mint-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzMintMTokenSucceed -vv

test-fuzz-borrow-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzBorrowMTokenSucceed -vv

test-fuzz-supplyReceive-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzSupplyReceivesRewards -vv


test-fuzz-borrowReceive-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzBorrowReceivesRewards -vv


test-fuzz-supplyBorrowReceive-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzSupplyBorrowReceiveRewards -vv

test-fuzz-liquidateAccountReceive-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testFuzzLiquidateAccountReceiveRewards -vv

test-fuzz-repayBorrowBehalfWethRouter-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testRepayBorrowBehalfWethRouter -vv

test-fuzz-repayMoreThanBorrowBalanceWethRouter-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testRepayMoreThanBorrowBalanceWethRouter -vv

test-fuzz-mintWithRouter-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testMintWithRouter -vv

test-fuzz-supplyingOverSupplyCapFails-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testSupplyingOverSupplyCapFails -vv

test-fuzz-borrowingOverBorrowCapFails-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testBorrowingOverBorrowCapFails -vv

test-fuzz-oraclesReturnCorrectValues-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testOraclesReturnCorrectValues -vv


test-fuzz-exitMarketFailsWhenNeededCrossCollateral-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	forge test --match-test testExitMarketFailsWhenNeededCrossCollateral -vv

test-invariant-marketsAreListedAndUnique-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-down >/dev/null 2>&1 || true; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	FOUNDRY_INVARIANT_RUNS="$(INVARIANT_RUNS)" \
	FOUNDRY_INVARIANT_DEPTH="$(INVARIANT_DEPTH)" \
	forge test \
		--match-test invariant_marketsAreListedAndUnique \
		-vv

test-invariant-accountMembershipBidirectionalTemplate-local:
	@set -e; \
	$(MAKE) ensure-mip-artifacts; \
	$(MAKE) anvil-forks-down >/dev/null 2>&1 || true; \
	$(MAKE) anvil-forks-up; \
	trap '$(MAKE) anvil-forks-down' EXIT; \
	MOONBEAM_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_MOONBEAM_PORT)" \
	BASE_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_BASE_PORT)" \
	OP_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_OPTIMISM_PORT)" \
	ETH_RPC_URL="http://$(ANVIL_HOST):$(ANVIL_ETHEREUM_PORT)" \
	FOUNDRY_INVARIANT_RUNS="$(INVARIANT_RUNS)" \
	FOUNDRY_INVARIANT_DEPTH="$(INVARIANT_DEPTH)" \
	forge test \
		--match-test invariant_accountMembershipBidirectionalTemplate \
		-vv