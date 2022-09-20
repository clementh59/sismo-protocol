// SPDX-License-Identifier: MIT

pragma solidity ^0.8.14;
pragma experimental ABIEncoderV2;

import {IHydraS1IncrementalMerkleBase} from './IHydraS1IncrementalMerkleBase.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';

// Protocol imports
import {Request, Attestation, Claim} from '../../../core/libs/Structs.sol';

// Imports related to Hydra S1 ZK Proving Scheme
import {HydraS1Verifier, HydraS1Lib, HydraS1Claim, HydraS1ProofData, HydraS1ProofInput, HydraS1GroupProperties} from '../libs/HydraS1Lib.sol';
import {ICommitmentMapperRegistry} from '../../../periphery/utils/CommitmentMapperRegistry.sol';
import {IIncrementalMerkleTree} from '../../../periphery/utils/IncrementalMerkleTree.sol';

/**
 * @title Hydra-S1 Base Attester
 * @author Sismo
 * @notice Abstract contract that facilitates the use of the Hydra-S1 ZK Proving Scheme.
 * Hydra-S1 is single source, single group: it allows users to verify they are part of one and only one group at a time
 * It is inherited by the family of Hydra-S1 attesters.
 * It contains the user input checking and the ZK-SNARK proof verification.
 * We invite readers to refer to:
 *    - https://hydra-s1.docs.sismo.io for a full guide through the Hydra-S1 ZK Attestations
 *    - https://hydra-s1-circuits.docs.sismo.io for circuits, prover and verifiers of Hydra-S1
 
 
 **/
abstract contract HydraS1IncrementalMerkleBase is IHydraS1IncrementalMerkleBase, Initializable {
  using HydraS1Lib for HydraS1ProofData;

  // ZK-SNARK Verifier
  HydraS1Verifier immutable VERIFIER;
  // Registry storing the Commitment Mapper EdDSA Public key
  ICommitmentMapperRegistry immutable COMMITMENT_MAPPER_REGISTRY;
  // Registry storing the Registry Tree Roots of the Attester's available ClaimData
  IIncrementalMerkleTree immutable INCREMENTAL_MERKLE_TREE;

  /*******************************************************
    INITIALIZATION FUNCTIONS                           
  *******************************************************/
  /**
   * @dev Constructor. Initializes the contract
   * @param hydraS1VerifierAddress ZK Snark Verifier contract
   * @param incrementalMerkleTreeAddress Merkle Tree that contains the authorized addresses
   * @param commitmentMapperAddress Commitment mapper's public key registry
   */
  constructor(
    address hydraS1VerifierAddress,
    address incrementalMerkleTreeAddress,
    address commitmentMapperAddress
  ) {
    VERIFIER = HydraS1Verifier(hydraS1VerifierAddress);
    INCREMENTAL_MERKLE_TREE = IIncrementalMerkleTree(incrementalMerkleTreeAddress);
    COMMITMENT_MAPPER_REGISTRY = ICommitmentMapperRegistry(commitmentMapperAddress);
  }

  /**
   * @dev Getter of Hydra-S1 Verifier contract
   */
  function getVerifier() external view returns (HydraS1Verifier) {
    return VERIFIER;
  }

  /**
   * @dev Getter of Commitment Mapper Registry contract
   */
  function getCommitmentMapperRegistry() external view returns (ICommitmentMapperRegistry) {
    return COMMITMENT_MAPPER_REGISTRY;
  }

  /**
   * @dev Getter of Incremental Merkle Tree contract
   */
  function getIncrementalMerkleTree() external view returns (IIncrementalMerkleTree) {
    return INCREMENTAL_MERKLE_TREE;
  }

  /*******************************************************
    Hydra-S1 SPECIFIC FUNCTIONS
  *******************************************************/

  /**
   * @dev MANDATORY: must be implemented to return the ticket identifier from a user request
   * so it can be checked against snark input
   * ticket = hash(sourceSecretHash, ticketIdentifier), which is verified inside the snark
   * users bring sourceSecretHash as private input which guarantees privacy

   * This function MUST be implemented by Hydra-S1 attesters.
   * This is the core function that implements the logic of tickets

   * Do they get one ticket per claim?
   * Do they get 2 tickets per claim?
   * Do they get 1 ticket per claim, every month?
   * Take a look at Hydra-S1 Simple Attester for an example
   * @param claim user claim: part of a group of accounts, with a claimedValue for their account
   */
  function _getTicketIdentifierOfClaim(HydraS1Claim memory claim)
    internal
    view
    virtual
    returns (uint256);

  /**
   * @dev Checks whether the user claim and the snark public input are a match
   * @param claim user claim
   * @param input snark public input
   */
  function _validateInput(HydraS1Claim memory claim, HydraS1ProofInput memory input)
    internal
    view
    virtual
  {
    if (input.accountsTreeValue != claim.groupId)
      revert AccountsTreeValueMismatch(claim.groupId, input.accountsTreeValue);

    if (input.isStrict == claim.groupProperties.isScore)
      revert IsStrictMismatch(claim.groupProperties.isScore, input.isStrict);

    if (input.destination != claim.destination)
      revert DestinationMismatch(claim.destination, input.destination);

    if (input.chainId != block.chainid) revert ChainIdMismatch(block.chainid, input.chainId);

    if (input.value != claim.claimedValue) revert ValueMismatch(claim.claimedValue, input.value);

    if (!INCREMENTAL_MERKLE_TREE.isKnownRoot(input.registryRoot))
      revert MerkleRootMismatch(input.registryRoot);

    uint256[2] memory commitmentMapperPubKey = COMMITMENT_MAPPER_REGISTRY.getEdDSAPubKey();
    if (
      input.commitmentMapperPubKey[0] != commitmentMapperPubKey[0] ||
      input.commitmentMapperPubKey[1] != commitmentMapperPubKey[1]
    )
      revert CommitmentMapperPubKeyMismatch(
        commitmentMapperPubKey[0],
        commitmentMapperPubKey[1],
        input.commitmentMapperPubKey[0],
        input.commitmentMapperPubKey[1]
      );

    uint256 ticketIdentifier = _getTicketIdentifierOfClaim(claim);

    if (input.ticketIdentifier != ticketIdentifier)
      revert TicketIdentifierMismatch(ticketIdentifier, input.ticketIdentifier);
  }

  /**
   * @dev verify the groth16 mathematical proof
   * @param proofData snark public input
   */
  function _verifyProof(HydraS1ProofData memory proofData) internal view virtual {
    try
      VERIFIER.verifyProof(proofData.proof.a, proofData.proof.b, proofData.proof.c, proofData.input)
    returns (bool success) {
      if (!success) revert InvalidGroth16Proof('');
    } catch Error(string memory reason) {
      revert InvalidGroth16Proof(reason);
    } catch Panic(
      uint256 /*errorCode*/
    ) {
      revert InvalidGroth16Proof('');
    } catch (
      bytes memory /*lowLevelData*/
    ) {
      revert InvalidGroth16Proof('');
    }
  }
}
