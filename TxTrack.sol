// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  TxTrack
/// @notice Public onchain analytics registry.
///         Projects register their contract address once, then push user
///         and transaction activity onchain. Anyone can query freely.
/// @dev    Deploy once on Botchain. No ownership required for logging —
///         any caller can push data for a registered contract.
contract TxTrack {

    // ─── Structs ───────────────────────────────────────────────────────────

    struct ContractInfo {
        address contractAddr;
        string  name;
        string  category;
        string  description;
        address registeredBy;
        uint256 registeredAt;
        bool    exists;
    }

    struct UserRecord {
        address wallet;
        string  eventType;    // e.g. "Registration", "FirstTx", "Deposit"
        uint256 firstSeenAt;
        uint256 txCount;      // total txs this wallet made on this contract
    }

    struct TxRecord {
        address wallet;
        string  action;
        uint256 timestamp;
        uint256 blockNumber;
    }

    struct Stats {
        uint256 totalUsers;    // total logUser() calls
        uint256 uniqueWallets; // distinct wallet addresses
        uint256 totalTxs;      // total logTx() calls
        uint256 eventCount;    // all events emitted (users + txs)
    }

    // ─── Storage ───────────────────────────────────────────────────────────

    /// contractAddr => metadata
    mapping(address => ContractInfo) public contracts;

    /// contractAddr => aggregate stats
    mapping(address => Stats) public stats;

    /// contractAddr => wallet => UserRecord
    mapping(address => mapping(address => UserRecord)) public userRecords;

    /// contractAddr => ordered list of unique wallet addresses
    mapping(address => address[]) public contractWallets;

    /// contractAddr => tx history (append-only)
    mapping(address => TxRecord[]) public txHistory;

    /// global list of all registered contract addresses
    address[] public registeredContracts;

    // ─── Events ────────────────────────────────────────────────────────────

    event ContractRegistered(
        address indexed contractAddr,
        string  name,
        address registeredBy,
        uint256 timestamp
    );

    event UserLogged(
        address indexed contractAddr,
        address indexed wallet,
        string  eventType,
        bool    isNewWallet,
        uint256 timestamp
    );

    event TxLogged(
        address indexed contractAddr,
        address indexed wallet,
        string  action,
        uint256 blockNumber,
        uint256 timestamp
    );

    // ─── Registration ──────────────────────────────────────────────────────

    /// @notice Register a project contract into the TxTrack registry.
    /// @param  contractAddr  The address of the project contract to track.
    /// @param  name          Human-readable project name.
    /// @param  category      e.g. "DeFi", "NFT", "Gaming", "Infrastructure".
    /// @param  description   Short description of what the contract does.
    function registerContract(
        address contractAddr,
        string calldata name,
        string calldata category,
        string calldata description
    ) external {
        require(!contracts[contractAddr].exists, "TxTrack: already registered");
        require(bytes(name).length > 0, "TxTrack: name required");

        contracts[contractAddr] = ContractInfo({
            contractAddr:   contractAddr,
            name:           name,
            category:       category,
            description:    description,
            registeredBy:   msg.sender,
            registeredAt:   block.timestamp,
            exists:         true
        });

        registeredContracts.push(contractAddr);

        emit ContractRegistered(contractAddr, name, msg.sender, block.timestamp);
    }

    // ─── Activity logging ──────────────────────────────────────────────────

    /// @notice Log a user interaction against a registered contract.
    ///         Increments uniqueWallets only on the first call per wallet.
    /// @param  contractAddr  The registered project contract address.
    /// @param  wallet        The user wallet address to record.
    /// @param  eventType     Type of interaction, e.g. "Registration", "Deposit".
    function logUser(
        address contractAddr,
        address wallet,
        string calldata eventType
    ) external {
        require(contracts[contractAddr].exists, "TxTrack: contract not registered");

        Stats storage s = stats[contractAddr];
        UserRecord storage u = userRecords[contractAddr][wallet];

        bool isNew = (u.firstSeenAt == 0);

        if (isNew) {
            userRecords[contractAddr][wallet] = UserRecord({
                wallet:      wallet,
                eventType:   eventType,
                firstSeenAt: block.timestamp,
                txCount:     1
            });
            contractWallets[contractAddr].push(wallet);
            s.uniqueWallets++;
        } else {
            u.txCount++;
        }

        s.totalUsers++;
        s.eventCount++;

        emit UserLogged(contractAddr, wallet, eventType, isNew, block.timestamp);
    }

    /// @notice Log a transaction from a wallet against a registered contract.
    /// @param  contractAddr  The registered project contract address.
    /// @param  wallet        The wallet that performed the action.
    /// @param  action        Action label, e.g. "Transfer", "Stake", "Claim".
    function logTx(
        address contractAddr,
        address wallet,
        string calldata action
    ) external {
        require(contracts[contractAddr].exists, "TxTrack: contract not registered");

        txHistory[contractAddr].push(TxRecord({
            wallet:      wallet,
            action:      action,
            timestamp:   block.timestamp,
            blockNumber: block.number
        }));

        Stats storage s = stats[contractAddr];
        s.totalTxs++;
        s.eventCount++;

        // bump per-wallet tx count if the wallet is already known
        if (userRecords[contractAddr][wallet].firstSeenAt != 0) {
            userRecords[contractAddr][wallet].txCount++;
        }

        emit TxLogged(contractAddr, wallet, action, block.number, block.timestamp);
    }

    // ─── Query functions (all view — free to call) ─────────────────────────

    /// @notice Get full aggregate stats for a contract in one call.
    function getStats(address contractAddr)
        external
        view
        returns (
            uint256 totalUsers,
            uint256 uniqueWallets,
            uint256 totalTxs,
            uint256 eventCount
        )
    {
        Stats memory s = stats[contractAddr];
        return (s.totalUsers, s.uniqueWallets, s.totalTxs, s.eventCount);
    }

    /// @notice Returns true if the contract has at least one recorded wallet.
    function hasUsers(address contractAddr) external view returns (bool) {
        return stats[contractAddr].uniqueWallets > 0;
    }

    /// @notice Returns all unique wallet addresses for a contract.
    function getWallets(address contractAddr)
        external
        view
        returns (address[] memory)
    {
        return contractWallets[contractAddr];
    }

    /// @notice Returns the total tx count for a specific wallet on a contract.
    function getWalletTxCount(address contractAddr, address wallet)
        external
        view
        returns (uint256)
    {
        return userRecords[contractAddr][wallet].txCount;
    }

    /// @notice Returns a paginated slice of the tx history for a contract.
    /// @param  offset  Starting index (0-based).
    /// @param  limit   Maximum number of records to return.
    function getTxHistory(
        address contractAddr,
        uint256 offset,
        uint256 limit
    ) external view returns (TxRecord[] memory page) {
        TxRecord[] storage all = txHistory[contractAddr];
        uint256 end = offset + limit > all.length ? all.length : offset + limit;
        if (offset >= all.length) return page;
        page = new TxRecord[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = all[i];
        }
    }

    /// @notice Returns all registered contract addresses.
    function getAllContracts() external view returns (address[] memory) {
        return registeredContracts;
    }

    /// @notice Returns full metadata for a registered contract.
    function getContractInfo(address contractAddr)
        external
        view
        returns (ContractInfo memory)
    {
        return contracts[contractAddr];
    }

    /// @notice Returns the total number of registered contracts.
    function getContractCount() external view returns (uint256) {
        return registeredContracts.length;
    }
}
