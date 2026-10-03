// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDOToken, IMDOFeeHook, IMDPoolKey} from "../src/IMDOFeeHook.sol";

/// @dev Foundry cheatcodes, declared locally so an offline build needs no script dependency.
interface IMDDeployVm {
    function envAddress(string calldata name) external view returns (address);
    function envBytes(string calldata name) external view returns (bytes memory);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function getCode(string calldata artifactPath) external view returns (bytes memory);
    function getDeployedCode(string calldata artifactPath) external view returns (bytes memory);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Prepare a factory launch and submit its configured atomic launch call.
/// @dev The launch factory ABI is deliberately not assumed. Its existing adapter must
/// encode FACTORY_CALLDATA using prepare()'s bytecode, salt and pool key. The factory
/// must create IMDOToken itself, deploy the hook with CREATE2, initialize the pool and
/// execute its normal liquidity/distribution flow in that same call.
contract Deploy {
    IMDDeployVm private constant vm = IMDDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant CHAIN_ID = 11_155_111;
    uint160 public constant HOOK_FLAGS = 0x25d4;
    uint160 public constant ALL_HOOK_FLAGS = 0x3fff;
    uint256 public constant MINE_ATTEMPTS = 1_000_000;
    address public constant TREASURY = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;

    struct LaunchPlan {
        address poolManager;
        address factory;
        address hookCreate2Deployer;
        address token;
        address hook;
        bytes32 hookSalt;
        bytes tokenCreationCode;
        bytes hookCreationCode;
        IMDPoolKey poolKey;
        bytes32 poolId;
    }

    error InvalidConfiguration();
    error SaltNotFound();
    error ExistingDeployment();
    error InvalidLaunchResult();

    event LaunchPrepared(
        address indexed factory,
        address indexed token,
        address indexed hook,
        address poolManager,
        address hookCreate2Deployer,
        bytes32 hookSalt,
        bytes32 tokenCreationCodeHash,
        bytes32 hookCreationCodeHash,
        bytes32 poolId,
        uint160 hookFlags
    );
    event LaunchAttested(
        uint256 indexed chainId,
        address indexed factory,
        bytes32 indexed poolId,
        address token,
        address hook,
        address treasury,
        uint256 initialSupply,
        uint24 poolFee,
        int24 tickSpacing,
        uint24 maximumHookFeePpm,
        bytes32 factoryCalldataHash
    );

    /// @notice Build the exact bytecodes, CREATE2 salt and pool key for a factory adapter.
    /// @dev TOKEN_ADDRESS is the factory's predicted token address; it need not exist yet.
    function prepare() public view returns (LaunchPlan memory plan) {
        plan.poolManager = vm.envAddress("POOL_MANAGER");
        plan.factory = vm.envAddress("LAUNCH_FACTORY");
        plan.token = vm.envAddress("TOKEN_ADDRESS");
        plan.hookCreate2Deployer = vm.envOr("HOOK_CREATE2_DEPLOYER", plan.factory);
        uint256 poolFee = vm.envOr("POOL_FEE", uint256(3_000));
        uint256 tickSpacing = vm.envOr("TICK_SPACING", uint256(60));
        if (
            plan.poolManager == address(0) || plan.factory == address(0) || plan.token == address(0)
                || plan.hookCreate2Deployer == address(0) || (poolFee != 500 && poolFee != 3_000 && poolFee != 10_000)
                || tickSpacing == 0 || tickSpacing > 32_767
        ) revert InvalidConfiguration();
        // Load this build's local artifacts instead of embedding both contracts in
        // the script runtime. No network or separately installed library is needed.
        plan.tokenCreationCode = vm.getCode("src/IMDOFeeHook.sol:IMDOToken");
        plan.hookCreationCode =
            abi.encodePacked(vm.getCode("src/IMDOFeeHook.sol:IMDOFeeHook"), abi.encode(plan.poolManager, plan.token));
        (plan.hookSalt, plan.hook) =
            mine(plan.hookCreate2Deployer, keccak256(plan.hookCreationCode), vm.envOr("SALT_START", uint256(0)));
        plan.poolKey = IMDPoolKey({
            currency0: address(0),
            currency1: plan.token,
            fee: uint24(poolFee),
            tickSpacing: int24(uint24(tickSpacing)),
            hooks: plan.hook
        });
        plan.poolId = keccak256(abi.encode(plan.poolKey));
    }

    /// @notice Find an address whose complete low 14 bits equal the enabled permissions.
    /// @dev Retry with another SALT_START if this bounded search is exhausted.
    function mine(address deployer, bytes32 initCodeHash, uint256 start)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < MINE_ATTEMPTS; ++i) {
            // Wrapping the search offset is safe: the salt is only a CREATE2 nonce.
            unchecked {
                salt = bytes32(start + i);
            }
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if ((uint160(predicted) & ALL_HOOK_FLAGS) == HOOK_FLAGS) return (salt, predicted);
        }
        revert SaltNotFound();
    }

    /// @notice Simulate by default; use Foundry's --broadcast only for an approved launch.
    /// @dev This makes exactly one factory call. It does not create an independent LP
    /// position, change factory payout recipients, or touch the Merkle distributor.
    function run() external returns (LaunchPlan memory plan) {
        if (block.chainid != CHAIN_ID) revert InvalidConfiguration();
        plan = prepare();
        if (plan.poolManager.code.length == 0 || plan.factory.code.length == 0) revert InvalidConfiguration();
        if (plan.token.code.length != 0 || plan.hook.code.length != 0) revert ExistingDeployment();
        bytes memory factoryCalldata = vm.envBytes("FACTORY_CALLDATA");
        if (factoryCalldata.length < 4) revert InvalidConfiguration();
        uint256 launchValue = vm.envOr("LAUNCH_VALUE", uint256(0));
        emit LaunchPrepared(
            plan.factory,
            plan.token,
            plan.hook,
            plan.poolManager,
            plan.hookCreate2Deployer,
            plan.hookSalt,
            keccak256(plan.tokenCreationCode),
            keccak256(plan.hookCreationCode),
            plan.poolId,
            HOOK_FLAGS
        );
        vm.startBroadcast();
        (bool success, bytes memory result) = plan.factory.call{value: launchValue}(factoryCalldata);
        vm.stopBroadcast();
        if (!success) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
        _attest(plan, keccak256(factoryCalldata));
    }

    function _attest(LaunchPlan memory plan, bytes32 calldataHash) private {
        if (
            plan.token.codehash != keccak256(vm.getDeployedCode("src/IMDOFeeHook.sol:IMDOToken"))
                || plan.hook.code.length == 0
        ) {
            revert InvalidLaunchResult();
        }
        IMDOToken token = IMDOToken(plan.token);
        IMDOFeeHook hook = IMDOFeeHook(plan.hook);
        if (
            token.totalSupply() != token.INITIAL_SUPPLY() || token.INITIAL_SUPPLY() != 1_000_000_000 ether
                || token.decimals() != 18 || keccak256(bytes(token.name())) != keccak256("IMD Offsets")
                || keccak256(bytes(token.symbol())) != keccak256("IMDO")
                || address(hook.poolManager()) != plan.poolManager || hook.token() != plan.token
                || hook.TREASURY() != TREASURY || hook.MAX_FEE_PPM() != 20_000 || hook.FLAGS() != HOOK_FLAGS
                || !hook.initialized() || hook.poolId() != plan.poolId
        ) revert InvalidLaunchResult();
        emit LaunchAttested(
            CHAIN_ID,
            plan.factory,
            plan.poolId,
            plan.token,
            plan.hook,
            TREASURY,
            token.INITIAL_SUPPLY(),
            plan.poolKey.fee,
            plan.poolKey.tickSpacing,
            hook.MAX_FEE_PPM(),
            calldataHash
        );
    }
}
