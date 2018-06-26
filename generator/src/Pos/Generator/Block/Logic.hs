{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE RankNTypes          #-}

-- | Blockchain generation logic.

module Pos.Generator.Block.Logic
       ( BlockTxpGenMode
       , genBlocks
       ) where

import           Universum

import           Control.Lens (at, ix, _Wrapped)
import           Control.Monad.Random.Strict (RandT, mapRandT)
import           Data.Default (Default)
import           Formatting (build, sformat, (%))
import           System.Random (RandomGen (..))
import           System.Wlog (logWarning)

import           Pos.AllSecrets (HasAllSecrets (..), unInvSecretsMap)
import           Pos.Block.Logic (applyBlocksUnsafe, createMainBlockInternal,
                     normalizeMempool, verifyBlocksPrefix)
import           Pos.Block.Lrc (lrcSingleShot)
import           Pos.Block.Slog (ShouldCallBListener (..))
import           Pos.Block.Types (Blund)
import           Pos.Communication.Message ()
import           Pos.Core as Core (Config (..), EpochOrSlot (..), SlotId (..),
                     addressHash, configEpochSlots, epochIndexL,
                     epochOrSlotEnumFromTo, epochOrSlotFromEnum,
                     epochOrSlotSucc, epochOrSlotToEnum, getEpochOrSlot,
                     getSlotIndex, localSlotIndexMinBound, pcBlkSecurityParam,
                     pcEpochSlots)
import           Pos.Core.Block (Block)
import           Pos.Core.Block.Constructors (mkGenesisBlock)
import           Pos.Crypto (pskDelegatePk)
import qualified Pos.DB.BlockIndex as DB
import           Pos.Delegation.Logic (getDlgTransPsk)
import           Pos.Delegation.Types (ProxySKBlockInfo)
import           Pos.Generator.Block.Error (BlockGenError (..))
import           Pos.Generator.Block.Mode (BlockGenMode, BlockGenRandMode,
                     MonadBlockGen, MonadBlockGenInit, mkBlockGenContext,
                     usingPrimaryKey, withCurrentSlot)
import           Pos.Generator.Block.Param (BlockGenParams,
                     HasBlockGenParams (..))
import           Pos.Generator.Block.Payload (genPayload)
import           Pos.Lrc.Context (lrcActionOnEpochReason)
import qualified Pos.Lrc.DB as LrcDB
import           Pos.Txp (MempoolExt, MonadTxpLocal, TxpGlobalSettings)
import           Pos.Txp.Configuration (HasTxpConfiguration)
import           Pos.Util (HasLens', maybeThrow, _neHead)

----------------------------------------------------------------------------
-- Block generation
----------------------------------------------------------------------------

type BlockTxpGenMode g ctx m =
    ( RandomGen g
    , MonadBlockGenInit ctx m
    , HasLens' ctx TxpGlobalSettings
    , Default (MempoolExt m)
    , MonadTxpLocal (BlockGenMode (MempoolExt m) m)
    )

-- | Generate an arbitrary sequence of valid blocks. The blocks are
-- valid with respect to the global state right before this function
-- call.
-- The blocks themselves can be combined and retained according to some monoid.
-- Intermediate results will be forced. Blocks can be generated, written to
-- disk, then collected by using '()' as the monoid and 'const ()' as the
-- injector, for example.
genBlocks
    :: forall g ctx m t
     . (HasTxpConfiguration, BlockTxpGenMode g ctx m, Semigroup t, Monoid t)
    => Core.Config
    -> BlockGenParams
    -> (Maybe Blund -> t)
    -> RandT g m t
genBlocks config params inj = do
    ctx <- lift $ mkBlockGenContext @(MempoolExt m) epochSlots params
    mapRandT (`runReaderT` ctx) genBlocksDo
  where
    epochSlots = configEpochSlots config
    genBlocksDo = do
        let numberOfBlocks = params ^. bgpBlockCount
        tipEOS <- getEpochOrSlot <$> lift DB.getTipHeader
        let startEOS = epochOrSlotSucc epochSlots tipEOS
        let finishEOS =
                epochOrSlotToEnum epochSlots
                    $ epochOrSlotFromEnum epochSlots tipEOS
                    + fromIntegral numberOfBlocks
        foldM' genOneBlock
               mempty
               (epochOrSlotEnumFromTo epochSlots startEOS finishEOS)

    genOneBlock t eos = ((t <>) . inj) <$> genBlock config eos

    foldM' combine = go
      where
        go !base []       = return base
        go !base (x : xs) = combine base x >>= flip go xs

-- Generate a valid 'Block' for the given epoch or slot (genesis block
-- in the former case and main block the latter case) and apply it.
genBlock
    :: forall g ctx m
     . ( RandomGen g
       , MonadBlockGen ctx m
       , Default (MempoolExt m)
       , MonadTxpLocal (BlockGenMode (MempoolExt m) m)
       , HasTxpConfiguration
       )
    => Core.Config
    -> EpochOrSlot
    -> BlockGenRandMode (MempoolExt m) g m (Maybe Blund)
genBlock config@(Config pm pc _) eos = do
    let epoch = eos ^. epochIndexL
    lift $ unlessM ((epoch ==) <$> LrcDB.getEpoch) (lrcSingleShot config epoch)
    -- We need to know leaders to create any block.
    leaders <- lift
        $ lrcActionOnEpochReason epoch "genBlock" LrcDB.getLeadersForEpoch
    case eos of
        EpochOrSlot (Left _) -> do
            tipHeader <- lift DB.getTipHeader
            let slot0 = SlotId epoch localSlotIndexMinBound
            let genesisBlock =
                    mkGenesisBlock pm (Right tipHeader) epoch leaders
            fmap Just $ withCurrentSlot slot0 $ lift $ verifyAndApply
                (Left genesisBlock)
        EpochOrSlot (Right slot@SlotId {..}) -> withCurrentSlot slot $ do
            genPayload pm (pcEpochSlots pc) slot
            leader <- lift $ maybeThrow
                (BGInternal "no leader")
                (leaders ^? ix (fromIntegral $ getSlotIndex siSlot))
            secrets <-
                unInvSecretsMap . view asSecretKeys <$> view blockGenParams
            transCert <- lift $ getDlgTransPsk leader
            let creator =
                    maybe leader (addressHash . pskDelegatePk . snd) transCert
            let maybeLeader = secrets ^. at creator
            canSkip <- view bgpSkipNoKey
            case (maybeLeader, canSkip) of
                (Nothing, True) -> do
                    lift $ logWarning $ sformat
                        ( "Skipping block creation for leader "
                        % build
                        % " as no related key was found"
                        )
                        leader
                    pure Nothing
                (Nothing      , False) -> throwM $ BGUnknownSecret leader
                -- When we know the secret key we can proceed to the actual creation.
                (Just leaderSK, _    ) -> Just <$> usingPrimaryKey
                    leaderSK
                    (lift $ genMainBlock slot (swap <$> transCert))
  where
    genMainBlock
        :: SlotId -> ProxySKBlockInfo -> BlockGenMode (MempoolExt m) m Blund
    genMainBlock slot proxySkInfo =
        createMainBlockInternal pm (pcBlkSecurityParam pc) slot proxySkInfo
            >>= \case
                    Left  err       -> throwM (BGFailedToCreate err)
                    Right mainBlock -> verifyAndApply $ Right mainBlock
    verifyAndApply :: Block -> BlockGenMode (MempoolExt m) m Blund
    verifyAndApply block = verifyBlocksPrefix pm pc (one block) >>= \case
        Left  err                   -> throwM (BGCreatedInvalid err)
        Right (undos, pollModifier) -> do
            let undo  = undos ^. _Wrapped . _neHead
                blund = (block, undo)
            applyBlocksUnsafe pm
                              pc
                              (ShouldCallBListener True)
                              (one blund)
                              (Just pollModifier)
            normalizeMempool pm pc
            pure blund
