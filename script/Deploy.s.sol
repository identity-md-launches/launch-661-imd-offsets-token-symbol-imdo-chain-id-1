// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMDOToken, IMDOFeeHook} from "../src/IMDOFeeHook.sol";

/// @dev Foundry cheatcodes, declared locally so an offline build needs no script dependency.
interface IMDDeployVm {
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @notice Code-only stand-in used ONLY on the local chain (31337) when no POOL_MANAGER is given.
/// @dev The hook's constructor refuses a manager address without code. A fresh local EVM has no
/// Uniswap v4 PoolManager, so the offline dry run deploys this empty contract in its place. It
/// implements nothing, so no pool can ever be initialized against it. It is never deployed on the
/// target chain: there a real POOL_MANAGER address is mandatory.
contract LocalPoolManagerStandIn {}

/// @notice Reference deployment of the IMDO token and its immutable sell-fee hook.
/// @dev Reads no keys. Configuration is the environment variable EXPECTED_CHAIN_ID (0 accepts the
/// current chain; otherwise it must equal block.chainid) and, on the target chain, POOL_MANAGER.
/// The chain must be 31337 (local dry run) or 11155111 (Sepolia). Between the broadcast markers the
/// script deploys IMDOToken with CREATE and IMDOFeeHook with CREATE2 through Foundry's default
/// deterministic deployer, using a salt mined here so the hook address carries exactly the
/// permission bits 0x25d4. Pool initialization is NOT part of this script: the launch factory
/// initializes the ETH/IMDO pool with this hook attached, which the hook accepts exactly once.
contract Deploy {
    /// @dev Same marker forge-std's Script carries: tells Foundry this contract is tooling, never deployed.
    bool public constant IS_SCRIPT = true;
    IMDDeployVm private constant vm = IMDDeployVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant LOCAL_CHAIN_ID = 31_337;
    uint256 public constant CHAIN_ID = 11_155_111;
    /// @dev Foundry routes `new X{salt: s}` through this deployer while broadcasting.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 public constant HOOK_FLAGS = 0x25d4;
    uint160 public constant ALL_HOOK_FLAGS = 0x3fff;
    uint256 public constant MINE_ATTEMPTS = 1_000_000;
    address public constant TREASURY = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;

    error InvalidConfiguration();
    error SaltNotFound();
    error InvalidLaunchResult();

    event LaunchAttested(
        uint256 indexed chainId,
        address indexed token,
        address indexed hook,
        address poolManager,
        bytes32 hookSalt,
        uint160 hookFlags,
        address treasury,
        uint256 initialSupply,
        uint24 maximumHookFeePpm,
        bytes32 tokenCreationCodeHash,
        bytes32 hookCreationCodeHash
    );

    /// @notice Simulate by default; use Foundry's --broadcast only for an approved launch.
    /// @dev Deploys exactly the token and the hook (plus the local stand-in manager on 31337 only).
    /// It creates no pool, no liquidity position and touches no factory or distributor.
    function run() external returns (IMDOToken token, IMDOFeeHook hook, bytes32 salt) {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (block.chainid != LOCAL_CHAIN_ID && block.chainid != CHAIN_ID) revert InvalidConfiguration();
        if (expected != 0 && expected != block.chainid) revert InvalidConfiguration();
        address manager = vm.envOr("POOL_MANAGER", address(0));
        // The real PoolManager is never hardcoded: on the target chain it must be configured.
        if (manager == address(0) ? block.chainid != LOCAL_CHAIN_ID : manager.code.length == 0) {
            revert InvalidConfiguration();
        }

        vm.startBroadcast();
        if (manager == address(0)) manager = address(new LocalPoolManagerStandIn());
        token = new IMDOToken();
        address predicted;
        (salt, predicted) = mine(CREATE2_DEPLOYER, keccak256(hookCreationCode(manager, address(token))), 0);
        hook = new IMDOFeeHook{salt: salt}(manager, address(token));
        vm.stopBroadcast();

        if (address(hook) != predicted) revert InvalidLaunchResult();
        _attest(token, hook, manager, salt);
    }

    /// @notice The exact CREATE2 init code of the hook for a manager and token pair.
    function hookCreationCode(address manager, address launchToken) public pure returns (bytes memory) {
        return abi.encodePacked(type(IMDOFeeHook).creationCode, abi.encode(manager, launchToken));
    }

    /// @notice Find an address whose complete low 14 bits equal the enabled permissions.
    /// @dev Bounded search; a different start continues it. The salt is only a CREATE2 nonce.
    function mine(address deployer, bytes32 initCodeHash, uint256 start)
        public
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < MINE_ATTEMPTS; ++i) {
            unchecked {
                salt = bytes32(start + i);
            }
            predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if ((uint160(predicted) & ALL_HOOK_FLAGS) == HOOK_FLAGS) return (salt, predicted);
        }
        revert SaltNotFound();
    }

    function _attest(IMDOToken token, IMDOFeeHook hook, address manager, bytes32 salt) private {
        if (
            token.totalSupply() != token.INITIAL_SUPPLY() || token.INITIAL_SUPPLY() != 1_000_000_000 ether
                || token.decimals() != 18 || keccak256(bytes(token.name())) != keccak256("IMD Offsets")
                || keccak256(bytes(token.symbol())) != keccak256("IMDO") || address(hook.poolManager()) != manager
                || hook.token() != address(token) || hook.TREASURY() != TREASURY || hook.MAX_FEE_PPM() != 20_000
                || hook.FLAGS() != HOOK_FLAGS || (uint160(address(hook)) & ALL_HOOK_FLAGS) != HOOK_FLAGS
                || hook.initialized()
        ) revert InvalidLaunchResult();
        emit LaunchAttested(
            block.chainid,
            address(token),
            address(hook),
            manager,
            salt,
            HOOK_FLAGS,
            TREASURY,
            token.INITIAL_SUPPLY(),
            hook.MAX_FEE_PPM(),
            keccak256(type(IMDOToken).creationCode),
            keccak256(type(IMDOFeeHook).creationCode)
        );
    }
}
