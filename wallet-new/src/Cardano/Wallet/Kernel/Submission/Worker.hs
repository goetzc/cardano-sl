module Cardano.Wallet.Kernel.Submission.Worker (
    tickSubmissionLayer
    ) where

import           Universum

import           Control.Concurrent (threadDelay)
import           Formatting (sformat, (%))
import qualified Formatting as F

import           System.Wlog (Severity (..))


tickSubmissionLayer :: forall m. (MonadCatch m, MonadIO m)
                    => (Severity -> Text -> m ())
                    -- ^ A logging function
                    -> IO ()
                    -- ^ A function to call at each 'tick' of the worker.
                    -- This callback will be responsible for doing any pre
                    -- and post processing of the state.
                    -> m ()
tickSubmissionLayer logFunction tick =
    go `catch` (\(e :: SomeException) ->
                   let msg = "Terminating tickSubmissionLayer due to " % F.shown
                   in logFunction Error (sformat msg e)
               )
    where
      go :: m ()
      go = do
          logFunction Debug "ticking the slot in the submission layer..."
          liftIO tick
          -- Wait 5 seconds between the next tick. In principle we could have
          -- chosen 20 seconds to make this delay match the @block time@ of the
          -- underlying protocol, but our submission layer's concept of time
          -- is completely independent by the time of the underlying blockchain,
          -- and this arbitrary choice of 5 seconds delay is yet another witness
          -- of such independence.
          liftIO $ threadDelay 5000000
          go
