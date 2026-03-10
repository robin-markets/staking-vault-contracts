// SPDX-License-Identifier: MIT
pragma solidity 0.8.31;

/// @title INegRiskAdapterEE
/// @notice NegRiskAdapter Errors and Events
interface INegRiskAdapterEE {
    error InvalidIndexSet();
    error LengthMismatch();
    error UnexpectedCollateralToken();
    error NoConvertiblePositions();
    error NotApprovedForAll();

    event MarketPrepared(bytes32 indexed marketId, address indexed oracle, uint256 feeBips, bytes data);
    event QuestionPrepared(bytes32 indexed marketId, bytes32 indexed questionId, uint256 index, bytes data);
    event OutcomeReported(bytes32 indexed marketId, bytes32 indexed questionId, bool outcome);
    event PositionSplit(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsMerge(address indexed stakeholder, bytes32 indexed conditionId, uint256 amount);
    event PositionsConverted(address indexed stakeholder, bytes32 indexed marketId, uint256 indexed indexSet, uint256 amount);
    event PayoutRedemption(address indexed redeemer, bytes32 indexed conditionId, uint256[] amounts, uint256 payout);
}

/// @title NegRiskAdapter
/// @notice Adapter for the CTF enabling the linking of a set binary markets where only one can resolve true
/// @notice The adapter prevents more than one question in the same multi-outcome market from resolving true
/// @notice And the adapter allows for the conversion of a set of no positions, to collateral plus the set of
/// complementary yes positions
/// @author Mike Shrieve (mike@polymarket.com)
interface INegRiskAdapter is INegRiskAdapterEE {
    /*//////////////////////////////////////////////////////////////
                                  IDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the conditionId for a given questionId
    /// @param _questionId  - the questionId
    /// @return conditionId - the corresponding conditionId
    function getConditionId(bytes32 _questionId) external view returns (bytes32);

    /// @notice Returns the positionId for a given questionId and outcome
    /// @param _questionId  - the questionId
    /// @param _outcome     - the boolean outcome
    /// @return positionId  - the corresponding positionId
    function getPositionId(bytes32 _questionId, bool _outcome) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                             SPLIT POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Splits collateral to a complete set of conditional tokens for a single question
    /// @notice This function signature is the same as the CTF's splitPosition
    /// @param _collateralToken - the collateral token, must be the same as the adapter's collateral token
    /// @param _conditionId - the conditionId for the question
    /// @param _amount - the amount of collateral to split
    function splitPosition(address _collateralToken, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external;

    /// @notice Splits collateral to a complete set of conditional tokens for a single question
    /// @param _conditionId - the conditionId for the question
    /// @param _amount      - the amount of collateral to split
    function splitPosition(bytes32 _conditionId, uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                            MERGE POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Merges a complete set of conditional tokens for a single question to collateral
    /// @notice This function signature is the same as the CTF's mergePositions
    /// @param _collateralToken - the collateral token, must be the same as the adapter's collateral token
    /// @param _conditionId     - the conditionId for the question
    /// @param _amount          - the amount of collateral to merge
    function mergePositions(address _collateralToken, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external;

    /// @notice Merges a complete set of conditional tokens for a single question to collateral
    /// @param _conditionId - the conditionId for the question
    /// @param _amount      - the amount of collateral to merge
    function mergePositions(bytes32 _conditionId, uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                           ERC1155 OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Proxies ERC1155 balanceOf to the CTF
    /// @param _owner   - the owner of the tokens
    /// @param _id      - the positionId
    /// @return balance - the owner's balance
    function balanceOf(address _owner, uint256 _id) external view returns (uint256);

    /// @notice Proxies ERC1155 balanceOfBatch to the CTF
    /// @param _owners   - the owners of the tokens
    /// @param _ids      - the positionIds
    /// @return balances - the owners' balances
    function balanceOfBatch(address[] memory _owners, uint256[] memory _ids) external view returns (uint256[] memory);

    /// @notice Proxies ERC1155 safeTransferFrom to the CTF
    /// @notice Can only be called by an admin
    /// @notice Requires this contract to be approved for all
    /// @notice Requires the sender to be approved for all
    /// @param _from  - the owner of the tokens
    /// @param _to    - the recipient of the tokens
    /// @param _id    - the positionId
    /// @param _value - the amount of tokens to transfer
    /// @param _data  - the data to pass to the recipient
    function safeTransferFrom(address _from, address _to, uint256 _id, uint256 _value, bytes calldata _data) external;

    /*//////////////////////////////////////////////////////////////
                            REDEEM POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeem a set of conditional tokens for collateral
    /// @param _conditionId - conditionId of the conditional tokens to redeem
    /// @param _amounts     - amounts of conditional tokens to redeem
    /// _amounts should always have length 2, with the first element being the amount of yes tokens to redeem and the
    /// second element being the amount of no tokens to redeem
    function redeemPositions(bytes32 _conditionId, uint256[] calldata _amounts) external;

    /*//////////////////////////////////////////////////////////////
                            CONVERT POSITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Convert a set of no positions to the complementary set of yes positions plus collateral proportional to
    /// (# of no positions - 1)
    /// @notice If the market has a fee, the fee is taken from both collateral and the yes positions
    /// @param _marketId - the marketId
    /// @param _indexSet - the set of positions to convert, expressed as an index set where the least significant bit is
    /// the first question (index zero)
    /// @param _amount   - the amount of tokens to convert
    function convertPositions(bytes32 _marketId, uint256 _indexSet, uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                             PREPARE MARKET
    //////////////////////////////////////////////////////////////*/

    /// @notice Prepare a multi-outcome market
    /// @param _feeBips  - the fee for the market, out of 10_000
    /// @param _metadata     - metadata for the market
    /// @return marketId - the marketId
    function prepareMarket(uint256 _feeBips, bytes calldata _metadata) external returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                            PREPARE QUESTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Prepare a question for a given market
    /// @param _marketId   - the id of the market for which to prepare the question
    /// @param _metadata   - the question metadata
    /// @return questionId - the id of the resulting question
    function prepareQuestion(bytes32 _marketId, bytes calldata _metadata) external returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                             REPORT OUTCOME
    //////////////////////////////////////////////////////////////*/

    /// @notice Report the outcome of a question
    /// @param _questionId - the questionId to report
    /// @param _outcome    - the outcome of the question
    function reportOutcome(bytes32 _questionId, bool _outcome) external;
}
