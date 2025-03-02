// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;
import "./interfaces/IVotingEscrow.sol";

import "./interfaces/IGaugeFactory.sol";

contract Voter {
    address public ve; // immutable // the ve token that governs these contracts
    address public yfi; // immutable // reward token
    address public veYfiRewardPool; // immutable
    address public gaugefactory; // immutable
    uint256 public totalWeight; // total voting weight

    address[] public vaults; // all vaults viable for incentives
    mapping(address => address) public gauges; // vault => gauge
    mapping(address => address) public vaultForGauge; // gauge => vault
    mapping(address => uint256) public weights; // vault => weight
    mapping(address => mapping(address => uint256)) public votes; // address => vault => votes
    mapping(address => address[]) public vaultVote; // address => vault
    mapping(address => uint256) public usedWeights; // address => total voting weight of user
    mapping(address => bool) public isGauge;
    mapping(address => address) public delegation;
    mapping(address => address[]) public delegated;

    address public gov;

    event UpdatedGov(address gov);
    event Reset(address account);
    event Vote(address gauge, uint256 weigth);
    event VaultAdded(address vault);
    event Delegation(address sender, address recipient);

    constructor(
        address _ve,
        address _yfi,
        address _gaugefactory,
        address _veYfiRewardPool
    ) {
        ve = _ve;
        yfi = _yfi;
        gaugefactory = _gaugefactory;
        veYfiRewardPool = _veYfiRewardPool;
        gov = msg.sender;
    }

    function reset() external {
        _reset(msg.sender);
    }

    function getVaults() external view returns (address[] memory) {
        return vaults;
    }

    function _reset(address _account) internal {
        address[] storage _vaultVote = vaultVote[_account];
        uint256 _vaultVoteCnt = _vaultVote.length;
        uint256 _totalWeight = 0;

        for (uint256 i = 0; i < _vaultVoteCnt; i++) {
            address _vault = _vaultVote[i];
            uint256 _votes = votes[_account][_vault];

            if (_votes > 0) {
                _totalWeight += _votes;
                weights[_vault] -= _votes;
                votes[_account][_vault] -= _votes;
            }
        }
        totalWeight -= _totalWeight;
        usedWeights[_account] = 0;
        emit Reset(_account);
        delete vaultVote[_account];
    }

    function getDelegated(address _account)
        external
        view
        returns (address[] memory)
    {
        return delegated[_account];
    }

    function poke(address _account) external {
        address[] memory _vaultVote = vaultVote[_account];
        uint256 _vaultCnt = _vaultVote.length;
        uint256[] memory _weights = new uint256[](_vaultCnt);

        for (uint256 i = 0; i < _vaultCnt; i++) {
            _weights[i] = votes[_account][_vaultVote[i]];
        }

        _vote(_account, _vaultVote, _weights);
    }

    function _vote(
        address _account,
        address[] memory _vaultVote,
        uint256[] memory _weights
    ) internal {
        _reset(_account);
        uint256 _weight = IVotingEscrow(ve).balanceOf(_account);
        if (_weight == 0) return;

        uint256 _vaultCnt = _vaultVote.length;
        uint256 _totalVoteWeight = 0;
        uint256 _totalWeight = 0;
        uint256 _usedWeight = 0;

        for (uint256 i = 0; i < _vaultCnt; i++) {
            _totalVoteWeight += _weights[i];
        }

        for (uint256 i = 0; i < _vaultCnt; i++) {
            address _vault = _vaultVote[i];
            address _gauge = gauges[_vault];
            uint256 _vaultWeight = (_weights[i] * _weight) / _totalVoteWeight;

            if (isGauge[_gauge]) {
                _usedWeight += _vaultWeight;
                _totalWeight += _vaultWeight;
                weights[_vault] += _vaultWeight;
                vaultVote[_account].push(_vault);
                votes[_account][_vault] += _vaultWeight;
                emit Vote(_gauge, _vaultWeight);
            }
        }
        totalWeight += _totalWeight;
        usedWeights[_account] = _usedWeight;
    }

    function vote(
        address[] calldata _accounts,
        address[] calldata _vaultVote,
        uint256[] calldata _weights
    ) external {
        require(_vaultVote.length == _weights.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            require(
                _accounts[i] == msg.sender ||
                    delegation[_accounts[i]] == msg.sender
            );
            _vote(_accounts[i], _vaultVote, _weights);
        }
    }

    function vote(address[] calldata _vaultVote, uint256[] calldata _weights)
        external
    {
        require(_vaultVote.length == _weights.length);
        _vote(msg.sender, _vaultVote, _weights);
    }

    function setGov(address _gov) external {
        require(msg.sender == gov, "!authorized");

        require(_gov != address(0));
        gov = _gov;
        emit UpdatedGov(_gov);
    }

    function addVaultToRewards(
        address _vault,
        address _gov,
        address _rewardManager
    ) external returns (address) {
        require(msg.sender == gov, "gov");
        require(gauges[_vault] == address(0x0), "exist");

        address _gauge = IGaugeFactory(gaugefactory).createGauge(
            _vault,
            yfi,
            _gov,
            _rewardManager,
            ve,
            veYfiRewardPool
        );
        gauges[_vault] = _gauge;
        vaultForGauge[_gauge] = _vault;
        isGauge[_gauge] = true;
        vaults.push(_vault);
        emit VaultAdded(_vault);
        return _gauge;
    }

    function removeVaultFromRewards(address _vault) external {
        require(msg.sender == gov, "gov");
        require(gauges[_vault] != address(0x0), "!exist");
        address gauge = gauges[_vault];

        uint256 length = vaults.length;
        for (uint256 i = 0; i < length; i++) {
            if (vaults[i] == _vault) {
                vaults[i] = vaults[length - 1];
                vaults.pop();
                break;
            }
        }

        gauges[_vault] = address(0x0);
        vaultForGauge[gauge] = address(0x0);
        isGauge[gauge] = false;
    }

    /**
    @notice Delegate voting power to an address.
    @param _to the address that can use the voting power
     */
    function delegate(address _to, bool reset_) external {
        if (reset_) _reset(msg.sender);
        address oldTo = delegation[msg.sender];

        if (oldTo != address(0x0)) {
            address[] storage delgateList = delegated[oldTo];
            uint256 length = delgateList.length;
            for (uint256 i = 0; i < length; i++) {
                if (delgateList[i] == msg.sender) {
                    delgateList[i] = delegated[oldTo][length - 1];
                    delegated[oldTo].pop();
                    break;
                }
            }
        }

        delegation[msg.sender] = _to;
        if (_to != address(0x0)) delegated[_to].push(msg.sender);
        emit Delegation(msg.sender, _to);
    }
}
