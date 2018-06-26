-- | Higher-level functions working with GState DB.

module Pos.GState.GState
       ( prepareGStateDB
       ) where

import           Universum

import           Pos.Core (GenesisData (..), GenesisHash, HeaderHash,
                     ProtocolConstants, genesisData)
import           Pos.DB.Class (MonadDB)
import           Pos.DB.GState.Common (initGStateCommon, isInitialized,
                     setInitialized)
import           Pos.Delegation.DB (initGStateDlg)
import           Pos.GState.BlockExtra (initGStateBlockExtra)
import           Pos.Ssc.DB (initSscDB)
import           Pos.Txp.DB (initGStateStakes, initGStateUtxo)
import           Pos.Txp.GenesisUtxo (genesisUtxo)
import           Pos.Update.DB (initGStateUS)

-- | Put missing initial data into GState DB.
prepareGStateDB ::
       forall ctx m.
       ( MonadReader ctx m
       , MonadDB m
       )
    => ProtocolConstants
    -> GenesisHash
    -> HeaderHash
    -> m ()
prepareGStateDB pc genesisHash initialTip = unlessM isInitialized $ do
    initGStateCommon initialTip
    initGStateUtxo genesisUtxo
    initSscDB
    initGStateStakes genesisUtxo
    initGStateUS pc
    initGStateDlg $ gdHeavyDelegation genesisData
    initGStateBlockExtra genesisHash initialTip

    setInitialized

-- The following is not used in the project yet. To be added back at a
-- later stage when needed.

{-
usingGStateSnapshot :: (MonadRealDB ctx m, MonadMask m) => m a -> m a
usingGStateSnapshot action = do
    db <- _gStateDB <$> getNodeDBs
    let readOpts = rocksReadOpts db
    usingSnapshot db (\(Snapshot sn) ->
        usingReadOptions readOpts {Rocks.useSnapshot = Just sn} gStateDB action)
-}
