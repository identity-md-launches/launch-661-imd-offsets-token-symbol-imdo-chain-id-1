// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed launch supply, all minted to the deploying launch factory.
contract IMDOToken {
    string public constant name = "IMD Offsets";
    string public constant symbol = "IMDO";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public totalSupply = INITIAL_SUPPLY;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = approved - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

// ABI-equivalent v4 tuples. Kept here because this submission may not add dependencies.
struct IMDPoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct IMDSwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct IMDModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

struct IMDHookPermissions {
    bool beforeInitialize;
    bool afterInitialize;
    bool beforeAddLiquidity;
    bool afterAddLiquidity;
    bool beforeRemoveLiquidity;
    bool afterRemoveLiquidity;
    bool beforeSwap;
    bool afterSwap;
    bool beforeDonate;
    bool afterDonate;
    bool beforeSwapReturnDelta;
    bool afterSwapReturnDelta;
    bool afterAddLiquidityReturnDelta;
    bool afterRemoveLiquidityReturnDelta;
}

interface IMDPoolManager {
    function take(address currency, address to, uint256 amount) external;
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function unlock(bytes calldata data) external returns (bytes memory);
    function protocolFeesAccrued(address currency) external view returns (uint256);
}

/// @dev Self-contained adaptation of OpenZeppelin's BaseHookFee pattern:
/// manager-only afterSwap, positive unspecified-currency delta, independent LP fees,
/// ERC-6909 claims when immediate settlement is unavailable. No upstream dependency.
abstract contract BaseHookFee {
    IMDPoolManager public immutable poolManager;
    error OnlyPoolManager();
    error ReentrantCall();
    bytes32 private constant BUSY = keccak256("IMDO.callback.busy");

    constructor(address manager) {
        require(manager.code.length != 0, "manager has no code");
        poolManager = IMDPoolManager(manager);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = BUSY;
        uint256 busy;
        assembly ("memory-safe") { busy := tload(slot) }
        if (busy != 0) revert ReentrantCall();
        assembly ("memory-safe") { tstore(slot, 1) }
        _;
        assembly ("memory-safe") { tstore(slot, 0) }
    }

    function afterSwap(address, IMDPoolKey calldata key, IMDSwapParams calldata params, int256 delta, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, _afterSwap(key, params, delta));
    }

    function _afterSwap(IMDPoolKey calldata key, IMDSwapParams calldata params, int256 delta)
        internal
        virtual
        returns (int128);
}

/// @notice Immutable IMDO/native-ETH sell fee. There are no administrative entry points.
contract IMDOFeeHook is BaseHookFee {
    address public constant TREASURY = 0xb1eC9d1C36974d05eb9889eBf8A150b05791E559;
    uint24 public constant MAX_FEE_PPM = 20_000;
    uint256 public constant PPM = 1_000_000;
    uint160 public constant FLAGS = 0x25d4;
    uint256 public constant DIRECT_TAKE_GAS = 80_000;
    address public immutable token;
    bytes32 public poolId;
    bool public initialized;

    // Pool-attributed token inventory, including uncollected LP fees, excluding protocol
    // and hook fees. Never use the singleton manager's ERC-20 balance as a pool reserve.
    uint256 public liveReserve;
    uint256 public laggedReserve;
    uint256 public reserveBlock;
    uint256 public accruedETH;
    uint256 public accruedToken;
    bytes32 private constant PROTOCOL_BEFORE = keccak256("IMDO.protocol.before");
    bytes32 private constant HARVESTING = keccak256("IMDO.harvesting");

    error InvalidPool();
    error InvalidHookAddress();
    error FeeOverflow();
    event PoolBound(bytes32 indexed poolId);
    event HookFeeCharged(address indexed origin, uint24 rate, uint256 cumulativeSold, address currency, uint256 amount);
    event FeeClaimAccrued(address indexed currency, uint256 amount);
    event Harvested(uint256 ethAmount, uint256 burnedAmount);

    constructor(address manager, address launchToken) BaseHookFee(manager) {
        require(launchToken.code.length != 0, "token has no code");
        if (uint160(address(this)) & 0x3fff != FLAGS) revert InvalidHookAddress();
        token = launchToken;
        // Explicit economic invariant: every bracket is bounded by the hard cap.
        assert(5_000 <= MAX_FEE_PPM && 10_000 <= MAX_FEE_PPM && MAX_FEE_PPM == 20_000);
    }

    function getHookPermissions() external pure returns (IMDHookPermissions memory p) {
        p.beforeInitialize = true;
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.afterDonate = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address, IMDPoolKey calldata key, uint160)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4)
    {
        if (
            initialized || key.currency0 != address(0) || key.currency1 != token || key.hooks != address(this)
                || (key.fee != 500 && key.fee != 3_000 && key.fee != 10_000)
        ) revert InvalidPool();
        initialized = true;
        poolId = keccak256(abi.encode(key));
        reserveBlock = block.number;
        emit PoolBound(poolId);
        return this.beforeInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        IMDPoolKey calldata key,
        IMDModifyLiquidityParams calldata,
        int256 delta,
        int256,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int256) {
        _checkPool(key);
        _updateReserve(int128(delta));
        return (this.afterAddLiquidity.selector, 0);
    }

    function afterRemoveLiquidity(
        address,
        IMDPoolKey calldata key,
        IMDModifyLiquidityParams calldata,
        int256 delta,
        int256,
        bytes calldata
    ) external onlyPoolManager nonReentrant returns (bytes4, int256) {
        _checkPool(key);
        _updateReserve(int128(delta));
        return (this.afterRemoveLiquidity.selector, 0);
    }

    function afterDonate(address, IMDPoolKey calldata key, uint256, uint256 amount1, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4)
    {
        _checkPool(key);
        _rollReserve();
        liveReserve += amount1;
        return this.afterDonate.selector;
    }

    function beforeSwap(address, IMDPoolKey calldata key, IMDSwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        nonReentrant
        returns (bytes4, int256, uint24)
    {
        _checkPool(key);
        uint256 protocolFees = poolManager.protocolFeesAccrued(token);
        bytes32 slot = PROTOCOL_BEFORE;
        assembly ("memory-safe") { tstore(slot, protocolFees) }
        // Observation only: never override the factory's pool fee or specified delta.
        return (this.beforeSwap.selector, 0, 0);
    }

    function reserveSnapshot() public view returns (uint256) {
        return block.number > reserveBlock ? liveReserve : laggedReserve;
    }

    function feeRate(uint256 sold, uint256 reserve) public pure returns (uint24) {
        if (sold == 0) return 0;
        if (reserve == 0) return MAX_FEE_PPM; // No mature reserve: conservative, never divide by zero.
        // Compare against ceil(reserve * bps / 10_000) without a large product.
        if (sold < _threshold(reserve, 100)) return 0;
        if (sold < _threshold(reserve, 300)) return 5_000;
        if (sold < _threshold(reserve, 500)) return 10_000;
        return MAX_FEE_PPM;
    }

    function _threshold(uint256 reserve, uint256 bps) private pure returns (uint256) {
        return (reserve / 10_000) * bps + ((reserve % 10_000) * bps + 9_999) / 10_000;
    }

    function _afterSwap(IMDPoolKey calldata key, IMDSwapParams calldata params, int256 delta)
        internal
        override
        returns (int128)
    {
        _checkPool(key);
        int128 tokenDelta = int128(delta);
        int128 quoteDelta = int128(delta >> 128);
        _updateReserve(tokenDelta);
        uint256 protocolBefore;
        bytes32 slot = PROTOCOL_BEFORE;
        assembly ("memory-safe") { protocolBefore := tload(slot) }
        liveReserve -= poolManager.protocolFeesAccrued(token) - protocolBefore;
        // Classify by settled amounts, never the requested amount or a router-provided identity.
        if (tokenDelta >= 0) return 0;
        uint256 tokenIn = uint256(-int256(tokenDelta));
        uint256 quoteOut = quoteDelta > 0 ? uint256(int256(quoteDelta)) : 0;
        (uint256 fee, uint24 rate, uint256 sold) = _bill(tokenIn, quoteOut, params.amountSpecified < 0);
        // Both the hook delta and the final caller delta must fit v4's signed int128.
        uint256 headroom = params.amountSpecified < 0 ? uint256(uint128(type(int128).max)) : uint256(1) << 127;
        if (params.amountSpecified >= 0) headroom -= tokenIn;
        if (fee > headroom) revert FeeOverflow();
        if (fee != 0) {
            address currency = params.amountSpecified < 0 ? address(0) : token;
            _payOrAccrue(currency, fee);
            emit HookFeeCharged(tx.origin, rate, sold, currency, fee);
        }
        return int128(int256(fee));
    }

    /// @dev Reprice cumulative gross ETH proceeds at the cumulative token-size bracket.
    /// P stores fees already paid, valued at each leg's settled token/ETH exchange ratio,
    /// in ETH-wei * PPM. This also prevents an exact-in/exact-out mix resetting the bill.
    function _bill(uint256 tokenIn, uint256 quoteOut, bool exactInput)
        private
        returns (uint256 fee, uint24 rate, uint256 sold)
    {
        bytes32 base = keccak256(abi.encode("IMDO.transaction.billing", tx.origin));
        uint256 quote;
        uint256 paid;
        assembly ("memory-safe") {
            sold := tload(base)
            quote := tload(add(base, 1))
            paid := tload(add(base, 2))
        }
        sold += tokenIn;
        quote += quoteOut;
        rate = feeRate(sold, laggedReserve);
        assert(rate <= MAX_FEE_PPM);
        uint256 due = quote * rate - paid;
        // Per-leg bound: a leg is never billed more than its own size (ETH fee <= this leg's gross
        // ETH output, token fee <= this leg's settled token input). The swapper's ETH delta for a
        // sell therefore never turns negative, so output-only routers can settle every leg. Any
        // uncollected remainder of the cumulative bill stays in `due` and is charged on the next
        // sell leg of the same transaction; it can only be left unpaid by stopping, which is never
        // cheaper than having sold the already-billed cumulative amount alone.
        if (exactInput) {
            fee = due / PPM;
            if (fee > quoteOut) fee = quoteOut;
            paid += fee * PPM;
        } else if (quoteOut != 0) {
            fee = _mulDiv(due, tokenIn, quoteOut * PPM);
            if (fee > tokenIn) fee = tokenIn;
            paid += _mulDiv(fee, quoteOut * PPM, tokenIn);
        }
        assembly ("memory-safe") {
            tstore(base, sold)
            tstore(add(base, 1), quote)
            tstore(add(base, 2), paid)
        }
    }

    function _payOrAccrue(address currency, uint256 fee) private {
        if (currency == address(0)) {
            // Bound the optional external payment so a gas-consuming recipient cannot
            // consume the transaction's entire gas budget before the claim fallback.
            if (address(poolManager).balance >= fee) {
                try poolManager.take{gas: DIRECT_TAKE_GAS}(currency, TREASURY, fee) {
                    return;
                } catch {}
            }
            accruedETH += fee;
        } else {
            // Plain immutable IMDO has no transfer callbacks or privileged burn path.
            if (IMDOToken(token).balanceOf(address(poolManager)) >= fee) {
                poolManager.take(token, address(this), fee);
                IMDOToken(token).burn(fee);
                return;
            }
            accruedToken += fee;
        }
        poolManager.mint(address(this), uint256(uint160(currency)), fee);
        emit FeeClaimAccrued(currency, fee);
    }

    /// @notice Anyone can redeem only recorded hook fee claims; destinations cannot be supplied.
    function harvest() external nonReentrant {
        bytes32 slot = HARVESTING;
        assembly ("memory-safe") { tstore(slot, 1) }
        poolManager.unlock("");
        assembly ("memory-safe") { tstore(slot, 0) }
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        bytes32 slot = HARVESTING;
        uint256 harvesting;
        assembly ("memory-safe") { harvesting := tload(slot) }
        require(harvesting == 1, "no harvest");
        assembly ("memory-safe") { tstore(slot, 0) }
        uint256 ethAmount = accruedETH;
        uint256 tokenAmount = accruedToken;
        uint256 redeemedETH;
        uint256 redeemedToken;
        if (ethAmount != 0 && address(poolManager).balance >= ethAmount) {
            accruedETH = 0;
            poolManager.take{gas: DIRECT_TAKE_GAS}(address(0), TREASURY, ethAmount);
            poolManager.burn(address(this), 0, ethAmount);
            redeemedETH = ethAmount;
        }
        if (tokenAmount != 0 && IMDOToken(token).balanceOf(address(poolManager)) >= tokenAmount) {
            accruedToken = 0;
            poolManager.take(token, address(this), tokenAmount);
            poolManager.burn(address(this), uint256(uint160(token)), tokenAmount);
            IMDOToken(token).burn(tokenAmount);
            redeemedToken = tokenAmount;
        }
        emit Harvested(redeemedETH, redeemedToken);
        return "";
    }

    function _checkPool(IMDPoolKey calldata key) private view {
        if (!initialized || keccak256(abi.encode(key)) != poolId) revert InvalidPool();
    }

    function _rollReserve() private {
        if (block.number > reserveBlock) {
            laggedReserve = liveReserve;
            reserveBlock = block.number;
        }
    }

    function _updateReserve(int128 delta) private {
        _rollReserve();
        if (delta < 0) liveReserve += uint256(-int256(delta));
        else liveReserve -= uint256(int256(delta));
    }

    /// @dev Full-precision floor(x*y/d), using the standard 512-bit product and modular
    /// inverse construction. The caller bounds the final amount to v4's int128 range.
    function _mulDiv(uint256 x, uint256 y, uint256 d) private pure returns (uint256 result) {
        unchecked {
            uint256 lo;
            uint256 hi;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                lo := mul(x, y)
                hi := sub(sub(mm, lo), lt(mm, lo))
            }
            if (hi == 0) return lo / d;
            if (d <= hi) revert FeeOverflow();
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                hi := sub(hi, gt(remainder, lo))
                lo := sub(lo, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                lo := div(lo, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            lo |= hi * twos;
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = lo * inverse;
        }
    }
}
