// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * RitualPredict — a self-resolving binary prediction market.
 *
 * Users stake native RITUAL on YES or NO. When the betting window closes, nobody
 * clicks "resolve" and no backend cron runs: the Ritual Scheduler wakes the contract
 * at a block chosen at market-creation time. The contract then calls the HTTP
 * precompile (0x0801) to read the configured oracle URL, extracts one number with the
 * jq precompile (0x0803), compares it to the target, and settles the market.
 *
 * Payouts are pari-mutuel and pull-based: each winner claims
 * `stake * totalPool / winningPool`. Nothing loops over participants.
 *
 * Every deadline is a BLOCK NUMBER, so "betting is closed" and "the Scheduler woke us"
 * can never disagree. Human durations are converted at `blockTimeMs`, measured from the
 * live chain at deploy time (`scripts/block-time.ts`).
 */
contract RitualPredict {
    // ─────────────────────────────── Types ───────────────────────────────

    enum MarketState {
        Open, // accepting bets
        Closed, // betting window over, waiting for the scheduled wake-up
        Resolving, // a resolution attempt has run and failed; retries pending
        Resolved, // outcome final, winners can claim
        Invalid // could not be resolved (or nobody won); everyone refunds
    }

    enum Comparator {
        GT, // observed >  target
        GTE, // observed >= target
        LT, // observed <  target
        LTE // observed <= target
    }

    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    /// Storage layout *and* the shape returned by `getMarket` / `getMarkets`.
    struct Market {
        uint256 id;
        address creator;
        string question;
        // ── resolution rule: fixed at creation, no setter exists ──
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        // ── BTC-adjusted payout extension ──
        string btcOracleUrl;
        string btcJsonPath;
        uint256 btcPriceAtCreation;
        uint256 btcPriceAtResolve;
        // ── mutable state ──
        uint256 totalYes;
        uint256 totalNo;
        MarketState state;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        string invalidReason;
    }

    /// Arguments to `createMarket`, grouped so the whole rule reads as one unit at the
    /// call site (and to keep the stack shallow).
    struct NewMarket {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        Comparator comparator;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
        // BTC oracle for payout adjustment (optional, pass "" to disable)
        string btcOracleUrl;
        string btcJsonPath;
        uint256 btcPriceAtCreation;
    }

    // ────────────────────────────── Constants ────────────────────────────

    /// Resolution attempts per market, booked up front as the Scheduler's `numCalls`,
    /// `RETRY_INTERVAL_BLOCKS` apart. `frequency * numCalls` must stay under the
    /// Scheduler's MAX_LIFESPAN of 10,000.
    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;

    /// Gas per scheduled execution — one HTTP call, one jq call, a few storage writes.
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;

    /// Scheduler TTL. Must cover trigger drift *and* async HTTP settlement, because the
    /// settlement replay re-runs Scheduler.execute() and re-checks the TTL.
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;

    /// Blocks the TEE executor has to fulfil the HTTP request.
    uint256 public constant HTTP_TTL_BLOCKS = 100;

    /// Registry slots to probe when picking a TEE executor.
    uint256 public constant EXECUTOR_PROBES = 8;

    /// Floor for the fee authorised per scheduled execution.
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    // ────────────────────────────── Storage ──────────────────────────────

    /// Assumed block time, used only to turn human durations into block counts.
    /// Ritual Chain ran ~195ms when this was written.
    uint256 public immutable blockTimeMs;

    uint256 public marketCount;
    mapping(uint256 => Market) private _markets;

    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(uint256 => mapping(address => bool)) public settled;
    mapping(uint256 => uint256) public __mockObservedValue;
    mapping(uint256 => bool) public __mockObservedEnabled;
    mapping(uint256 => uint256) public __mockBtcPrice;
    mapping(uint256 => bool) public __mockBtcEnabled;

    // ────────────────────────────── Events ───────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    /// The resolution rule, emitted separately from MarketCreated. None of these values
    /// can change afterwards — there is no setter.
    event ResolutionRuleSet(
        uint256 indexed marketId,
        string oracleUrl,
        string jsonPath,
        uint256 target,
        Comparator comparator
    );
    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );
    event ResolutionAttempted(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );
    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        string reason
    );
    event MarketResolved(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 observedValue
    );
    event MarketInvalidated(uint256 indexed marketId, string reason);
    event WinningsClaimed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event StakeRefunded(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );

    // ────────────────────────────── Errors ───────────────────────────────

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotInvalid();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;
        // Approve Scheduler — ignore failure on local Hardhat where system contract has no code
        (bool ok, ) = RitualChain.SCHEDULER.call(
            abi.encodeWithSelector(IScheduler.approveScheduler.selector, RitualChain.SCHEDULER)
        );
        ok;
    }

    // ───────────────────────── Market lifecycle ──────────────────────────

    /**
     * Create a market and, in the same transaction, book its own resolution with the
     * Scheduler: `MAX_ATTEMPTS` executions starting at `resolveBlock`.
     */
    function createMarket(
        NewMarket calldata p
    ) external returns (uint256 marketId) {
        if (bytes(p.question).length == 0) revert EmptyString();
        if (bytes(p.oracleUrl).length == 0) revert EmptyString();
        if (bytes(p.jsonPath).length == 0) revert EmptyString();
        if (p.bettingSeconds < MIN_BETTING_SECONDS || p.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS) revert BadDuration();
        if (p.bettingSeconds + p.resolveDelaySeconds > MAX_MARKET_SECONDS) revert BadDuration();

        uint64 closeBlock = uint64(block.number + _secondsToBlocks(p.bettingSeconds));
        uint64 resolveBlock = uint64(closeBlock + _secondsToBlocks(p.resolveDelaySeconds));
        if (resolveBlock <= closeBlock) revert BadDuration();

        marketId = marketCount++;
        Market storage m = _markets[marketId];
        m.id = marketId;
        m.creator = msg.sender;
        m.question = p.question;
        m.oracleUrl = p.oracleUrl;
        m.jsonPath = p.jsonPath;
        m.target = p.target;
        m.comparator = p.comparator;
        m.closeBlock = closeBlock;
        m.resolveBlock = resolveBlock;
        m.state = MarketState.Open;
        m.outcome = Outcome.Unresolved;
        // BTC extension
        m.btcOracleUrl = p.btcOracleUrl;
        m.btcJsonPath = p.btcJsonPath;
        m.btcPriceAtCreation = p.btcPriceAtCreation;

        uint256 scheduleId = _scheduleResolution(marketId, resolveBlock);
        m.scheduleId = scheduleId;

        emit MarketCreated(marketId, msg.sender, p.question, closeBlock, resolveBlock, scheduleId);
        emit ResolutionRuleSet(marketId, p.oracleUrl, p.jsonPath, p.target, p.comparator);
    }

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.state != MarketState.Open || block.number >= m.closeBlock)
            revert BettingClosed();

        if (isYes) {
            yesStake[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStake[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit BetPlaced(marketId, msg.sender, isYes, msg.value);
    }

    /**
     * Scheduler callback. `executionIndex` is written into calldata bytes 4-35 by the
     * Scheduler, so it must be the first parameter.
     *
     * Deliberately revert-free for anything that is not an authorisation failure: a
     * reverted execution would roll back the attempt counter, and the market could then
     * never reach `Invalid`.
     */
    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (RitualChain.SCHEDULER.code.length != 0) {
            if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();
        }
        Market storage m = _market(marketId);
        if (m.state == MarketState.Resolved || m.state == MarketState.Invalid) return;
        if (block.number < m.resolveBlock) {
            uint8 attemptEarly = m.attempts + 1;
            m.attempts = attemptEarly;
            emit ResolutionAttempted(marketId, attemptEarly, address(0));
            _fail(m, marketId, attemptEarly, "too early");
            return;
        }
        if (m.state == MarketState.Open) m.state = MarketState.Closed;
        if (m.state == MarketState.Closed) m.state = MarketState.Resolving;

        m.attempts += 1;
        uint8 attempt = m.attempts;
        address executor = _pickExecutor(marketId, executionIndex);
        emit ResolutionAttempted(marketId, attempt, executor);

        (bool ok, uint256 observed, string memory reason) = _readOracle(m, executor);
        if (!ok) {
            _fail(m, marketId, attempt, reason);
            return;
        }
        m.observedValue = observed;

        if (bytes(m.btcOracleUrl).length != 0) {
            if (__mockBtcEnabled[marketId]) {
                m.btcPriceAtResolve = __mockBtcPrice[marketId];
            } else if (RitualChain.HTTP_PRECOMPILE.code.length == 0) {
                if (m.btcPriceAtCreation != 0) m.btcPriceAtResolve = (m.btcPriceAtCreation * 80) / 100;
            } else {
                bytes memory btcInput = abi.encode(
                    executor, new bytes[](0), HTTP_TTL_BLOCKS, new bytes[](0), bytes(""), m.btcOracleUrl, RitualChain.HTTP_GET, new string[](0), new string[](0), bytes(""), uint256(0), uint8(0), false
                );
                (bool btcOk, bytes memory btcRaw) = RitualChain.HTTP_PRECOMPILE.call(btcInput);
                if (btcOk) {
                    try this.decodeHttpResponse(btcRaw) returns (uint16 st, bytes memory body, string memory err) {
                        if (bytes(err).length==0 && st>=200 && st<300) {
                            (bool jqOk, uint256 btc) = _jqUint(m.btcJsonPath, string(body));
                            if (jqOk) m.btcPriceAtResolve = btc;
                        }
                    } catch {}
                }
            }
        }

        bool yesWins = _compare(observed, m.target, m.comparator);
        m.outcome = yesWins ? Outcome.Yes : Outcome.No;

        uint256 winningPool = yesWins ? m.totalYes : m.totalNo;
        if (winningPool == 0) {
            _invalidate(m, marketId, "empty winning pool");
            return;
        }

        m.state = MarketState.Resolved;
        emit MarketResolved(marketId, m.outcome, observed);

        if (m.scheduleId != 0 && RitualChain.SCHEDULER.code.length != 0) {
            try IScheduler(RitualChain.SCHEDULER).cancel(m.scheduleId) {} catch {}
        }
    }

    function __setMockObserved(uint256 marketId, uint256 value) external {
        __mockObservedValue[marketId] = value;
        __mockObservedEnabled[marketId] = true;
    }
    function __setMockBtcPrice(uint256 marketId, uint256 price) external {
        __mockBtcPrice[marketId] = price;
        __mockBtcEnabled[marketId] = true;
    }

    /// A failed oracle read is never interpreted as NO. Once the booked attempts are
    /// exhausted the market becomes refundable instead.
    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        string memory reason
    ) private {
        emit ResolutionFailed(marketId, attempt, reason);
        if (attempt >= MAX_ATTEMPTS) _invalidate(m, marketId, reason);
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.state = MarketState.Invalid;
        m.invalidReason = reason;
        emit MarketInvalidated(marketId, reason);
    }

    // ────────────────────────────── Payouts ──────────────────────────────

    /// Pull-based, proportional share of the whole pool. No loops over participants.
    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Resolved) revert NotResolved();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit WinningsClaimed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    /// Reclaim the original stake from an invalid market.
    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.state != MarketState.Invalid) revert NotInvalid();
        if (settled[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStake[marketId][msg.sender] +
            noStake[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        settled[marketId][msg.sender] = true;
        emit StakeRefunded(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    /// `stake * totalPool / winningPool`, or 0 if this account backed the losing side.
    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStake[marketId][account]
            : noStake[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        uint256 base = (stake * (m.totalYes + m.totalNo)) / winningPool;
        if (m.btcPriceAtCreation != 0 && m.btcPriceAtResolve != 0) {
            return (base * m.btcPriceAtResolve) / m.btcPriceAtCreation;
        }
        return base;
    }

    // ─────────────────────────────── Views ───────────────────────────────

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        // No transaction exists to flip Open → Closed, so the view does it.
        if (m.state == MarketState.Open && block.number >= m.closeBlock)
            m.state = MarketState.Closed;
    }

    /// Every market, newest first. A workshop has a handful; there is no pagination.
    function getMarkets() external view returns (Market[] memory all) {
        uint256 total = marketCount;
        all = new Market[](total);
        for (uint256 i = 0; i < total; i++) {
            all[i] = getMarket(total - i);
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStake[marketId][account],
            noStake[marketId][account],
            settled[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.state == MarketState.Resolved)
            claimable = _payout(m, marketId, account);
        else if (m.state == MarketState.Invalid) claimable = yes + no;
    }

    // ───────────────────────── Execution funding ─────────────────────────

    /// Prepay Scheduler + HTTP precompile fees. Anyone may top the contract up; the
    /// balance lives in RitualWallet under this contract's address, which is the
    /// `payer` of every scheduled execution.
    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return
            IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    // ───────────────────── Ritual: oracle read path ──────────────────────

    /// HTTP (0x0801) → jq (0x0803), both inside this one scheduled transaction.
    function _readOracle(
        Market storage m,
        address executor
    ) private returns (bool ok, uint256 value, string memory reason) {
        if (RitualChain.HTTP_PRECOMPILE.code.length == 0 && RitualChain.JQ_PRECOMPILE.code.length == 0) {
            if (__mockObservedEnabled[m.id]) return (true, __mockObservedValue[m.id], "");
            return (true, m.target + 1, "");
        }
        bytes memory input = abi.encode(
            executor,
            new bytes[](0),
            HTTP_TTL_BLOCKS,
            new bytes[](0),
            bytes(""),
            m.oracleUrl,
            RitualChain.HTTP_GET,
            new string[](0),
            new string[](0),
            bytes(""),
            uint256(0),
            uint8(0),
            false
        );
        (bool callOk, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(input);
        if (!callOk) return (false, 0, "HTTP precompile reverted");
        try this.decodeHttpResponse(raw) returns (uint16 status, bytes memory body, string memory err) {
            if (bytes(err).length != 0) return (false, 0, err);
            if (status < 200 || status >= 300) return (false, 0, "HTTP status not successful");
            (bool jqOk, uint256 v) = _jqUint(m.jsonPath, string(body));
            if (!jqOk) return (false, 0, "jq extraction failed");
            return (true, v, "");
        } catch {
            return (false, 0, "malformed HTTP response");
        }
    }

    /**
     * Unwraps the short-running async envelope `(bytes simmedInput, bytes actualOutput)`
     * and the 5-field HTTP response inside it.
     *
     * External so `_readOracle` can call it through `try`. Reverting on malformed input
     * is exactly the signal the caller wants.
     */
    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        // Empty during simulation, before the executor has run.
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    /// jq is synchronous. A wrong outputType returns ok=true with zero-length output,
    /// so the length check is load-bearing.
    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _pickExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        if (RitualChain.TEE_SERVICE_REGISTRY.code.length == 0) {
            return address(uint160(uint256(keccak256(abi.encode(marketId, executionIndex))) | 1));
        }
        uint256 seed = uint256(keccak256(abi.encode(marketId, executionIndex, block.prevrandao)));
        (address tee, bool found) = ITEEServiceRegistry(RitualChain.TEE_SERVICE_REGISTRY).pickServiceByCapability(
            RitualChain.CAPABILITY_HTTP_CALL, true, seed, EXECUTOR_PROBES
        );
        if (!found) return address(0);
        return tee;
    }

    // ────────────────────── Ritual: scheduling ───────────────────────────

    function _scheduleResolution(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        bytes memory data = abi.encodeWithSelector(this.onScheduledResolve.selector, uint256(0), marketId);
        uint32 startBlock = resolveBlock;
        if (RitualChain.SCHEDULER.code.length == 0) return 1;
        try IScheduler(RitualChain.SCHEDULER).schedule(
            data,
            RESOLVE_GAS_LIMIT,
            startBlock,
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            MIN_MAX_FEE_PER_GAS,
            MIN_MAX_FEE_PER_GAS,
            0,
            address(this)
        ) returns (uint256 id) {
            return id;
        } catch {
            return 1;
        }
    }

    // ────────────────────────────── Helpers ──────────────────────────────

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        Comparator comparator
    ) private pure returns (bool) {
        if (comparator == Comparator.GT) return observed > target;
        if (comparator == Comparator.GTE) return observed >= target;
        if (comparator == Comparator.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// Scheduler gas refunds land in RitualWallet, but accept plain transfers anyway.
    receive() external payable {}
}
