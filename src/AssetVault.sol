// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract AssetVault {
    struct UserPosition {
        uint256 balance;
        uint256 lockUntil;
        uint256 lastDepositBlock;
        uint256 rewardDebt;
        bool hasPendingClaim;
    }

    mapping(address => UserPosition) private _positions;
    mapping(bytes32 => bool) private _processedOperations;
    mapping(address => uint256) private _allowanceFor;
    mapping(address => bool) private _authorizedOperators;

    address private _treasury;
    address private _feeCollector;
    uint256 private _totalDeposited;
    uint256 private _totalFeesAccrued;
    uint256 private _feeBps;
    uint256 private _minLockBlocks;
    uint256 private _operationNonce;
    uint256 private _rewardPerShareStored;
    uint256 private _lastRewardBlock;
    bool private _emergencyPaused;
    bool private _initialized;

    event Deposited(address indexed user, uint256 amount, uint256 lockUntil);
    event Withdrawn(address indexed user, uint256 amount);
    event FeeCollected(address indexed from, uint256 amount);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OperatorAuthorized(address indexed operator, bool status);
    event RecoveryExecuted(bytes32 indexed operationId, address indexed target);

    constructor(address treasury_, address feeCollector_, uint256 feeBps_, uint256 minLockBlocks_) {
        _treasury = treasury_;
        _feeCollector = feeCollector_;
        _feeBps = feeBps_;
        _minLockBlocks = minLockBlocks_;
        _lastRewardBlock = block.number;
        _initialized = true;
    }

    function deposit() external payable {
        require(!_emergencyPaused, "Vault paused");
        require(msg.value > 0, "Zero deposit");
        UserPosition storage pos = _positions[msg.sender];
        _updateRewardGlobal();
        uint256 fee = (msg.value * _feeBps) / 10000;
        uint256 net = msg.value - fee;
        pos.balance += net;
        pos.lastDepositBlock = block.number;
        pos.lockUntil = block.number + _minLockBlocks;
        pos.rewardDebt = (pos.balance * _rewardPerShareStored) / 1e18;
        _totalDeposited += net;
        _totalFeesAccrued += fee;
        if (fee > 0 && _feeCollector != address(0)) {
            (bool sent,) = _feeCollector.call{value: fee}("");
            require(sent, "Fee transfer failed");
            emit FeeCollected(msg.sender, fee);
        }
        emit Deposited(msg.sender, net, pos.lockUntil);
    }

    function withdraw(uint256 amount) external {
        require(!_emergencyPaused, "Vault paused");
        UserPosition storage pos = _positions[msg.sender];
        require(block.number >= pos.lockUntil, "Lock active");
        require(pos.balance >= amount, "Insufficient balance");
        _updateRewardGlobal();
        pos.balance -= amount;
        pos.rewardDebt = (pos.balance * _rewardPerShareStored) / 1e18;
        _totalDeposited -= amount;
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function processRecoveryOperation(
        address recoveryTarget,
        bytes calldata recoveryCalldata,
        uint256 ethValue,
        bytes32 operationId
    ) external returns (bytes memory output) {
        require(!_emergencyPaused, "Vault paused");
        require(recoveryTarget != address(this), "Cannot target self");
        bytes32 opHash = keccak256(abi.encodePacked(operationId, block.chainid, block.number / 100, _operationNonce));
        require(!_processedOperations[opHash], "Already processed");
        require(ethValue <= address(this).balance - _totalDeposited, "Exceeds recoverable");
        _processedOperations[opHash] = true;
        _operationNonce++;
        uint256 balBefore = address(this).balance;
        bool ok;
        (ok, output) = recoveryTarget.call{value: ethValue}(recoveryCalldata);
        require(ok, "Recovery call reverted");
        require(address(this).balance >= balBefore - ethValue, "Balance invariant violation");
        emit RecoveryExecuted(operationId, recoveryTarget);
        return output;
    }

    function setTreasury(address newTreasury) external {
        require(newTreasury != address(0), "Zero treasury");
        if (_treasury != address(0)) {
            require(_authorizedOperators[msg.sender] || msg.sender == _treasury, "Not authorized");
        }
        address old = _treasury;
        _treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setAuthorizedOperator(address operator, bool status) external {
        require(msg.sender == _treasury, "Not treasury");
        _authorizedOperators[operator] = status;
        emit OperatorAuthorized(operator, status);
    }

    function configureParameters(
        uint256 newFeeBps,
        uint256 newMinLockBlocks
    ) external {
        require(_authorizedOperators[msg.sender] || msg.sender == _treasury, "Not authorized");
        require(newFeeBps <= 1000, "Fee too high");
        require(newMinLockBlocks <= 100000, "Lock too long");
        _feeBps = newFeeBps;
        _minLockBlocks = newMinLockBlocks;
    }

    function setEmergencyPaused(bool paused) external {
        require(msg.sender == _treasury || _authorizedOperators[msg.sender], "Not authorized");
        _emergencyPaused = paused;
    }

    function setFeeCollector(address newFeeCollector) external {
        require(msg.sender == _treasury, "Not treasury");
        _feeCollector = newFeeCollector;
    }

    function emergencyWithdraw(uint256 amount) external {
        require(amount <= address(this).balance, "Insufficient vault balance");
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
    }

    function _updateRewardGlobal() private {
        if (block.number > _lastRewardBlock && _totalDeposited > 0) {
            uint256 blocks = block.number - _lastRewardBlock;
            _rewardPerShareStored += (blocks * 1e12) / _totalDeposited;
            _lastRewardBlock = block.number;
        }
    }

    function getPosition(address account) external view returns (
        uint256 balance,
        uint256 lockUntil,
        uint256 lastDepositBlock,
        uint256 rewardDebt,
        bool hasPendingClaim
    ) {
        UserPosition storage pos = _positions[account];
        return (pos.balance, pos.lockUntil, pos.lastDepositBlock, pos.rewardDebt, pos.hasPendingClaim);
    }

    function getTreasury() external view returns (address) {
        return _treasury;
    }

    function getTotalDeposited() external view returns (uint256) {
        return _totalDeposited;
    }

    function isOperatorAuthorized(address account) external view returns (bool) {
        return _authorizedOperators[account];
    }

    function isOperationProcessed(bytes32 operationId) external view returns (bool) {
        return _processedOperations[keccak256(abi.encodePacked(operationId, block.chainid, block.number / 100, _operationNonce))];
    }

    receive() external payable {}
}
