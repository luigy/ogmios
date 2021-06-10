-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications #-}

module Test.App.Protocol.Util
    ( prop_inIOSim
    , expectWSPResponse
    , withMockChannel

      -- * Exceptions
    , PeerTerminatedUnexpectedly (..)
    , UnexpectedResponse (..)
    ) where

import Ogmios.Prelude

import Control.Exception
    ( evaluate )
import Control.Monad.IOSim
    ( runSimOrThrow )
import GHC.TypeLits
    ( KnownSymbol, Symbol, symbolVal )
import Ogmios.Control.Exception
    ( MonadThrow (..) )
import Ogmios.Control.MonadAsync
    ( race )
import Ogmios.Control.MonadOuroboros
    ( MonadOuroboros )
import Ogmios.Control.MonadSTM
    ( MonadSTM (..), newTQueue, readTQueue, writeTQueue )
import Ogmios.Data.Json.Prelude
    ( at, inefficientEncodingToValue )
import Ouroboros.Network.Channel
    ( Channel (..) )
import System.Random
    ( StdGen, mkStdGen )
import Test.QuickCheck
    ( Property, arbitrary )
import Test.QuickCheck.Monadic
    ( monadicIO, pick, run )

import qualified Data.Aeson as Json

-- | Run a function in IOSim, with a 'StdGen' input which can used to compute
-- random numbers deterministically within the simulation. The random generator
-- is however randomly seeded for each property run.
prop_inIOSim
    :: (forall m. (MonadSTM m, MonadOuroboros m) => StdGen -> m ())
    -> Property
prop_inIOSim action = monadicIO $ do
    seed <- mkStdGen <$> pick arbitrary
    run $ evaluate $ runSimOrThrow $ action seed

-- Run an action concurrently with a peer, and a 'fake' channel connected to
-- TQueue. The peer is expected to consume and produce values from and to the
-- TQueue to drive the channel communication.
withMockChannel
    :: forall m a. (MonadSTM m, MonadOuroboros m)
    => ((m LByteString, LByteString -> m ()) -> m ())
        -- ^ A mock peer for consuming the data.
    -> (Channel m LByteString -> m a)
        -- ^ Callback using the channel
    -> m a
withMockChannel mockPeer action = do
    (readBuffer, writeBuffer) <- atomically $ (,) <$> newTQueue <*> newTQueue
    let send = atomically . writeTQueue writeBuffer
    let recv = Just <$> atomically (readTQueue readBuffer)
    let channel = Channel{send,recv}
    let sendDual = atomically (readTQueue writeBuffer)
    let recvDual = atomically . writeTQueue readBuffer
    result <- race (mockPeer (sendDual, recvDual)) (action channel)
    either (const $ error "mockNode terminated?") pure result

-- | Assert that a given JSON object is a JSON-WSP response for the given
-- method.
--
-- >>> expectWSPResponse @"RequestNext" recv Nothing
-- ()
expectWSPResponse
    :: forall (method :: Symbol) m. (MonadThrow m, KnownSymbol method)
    => m Json.Encoding
    -> Json.Value
    -> m ()
expectWSPResponse recv wantMirror = do
    json <- inefficientEncodingToValue <$> recv

    let gotMethod = "methodname" `at` json
    let wantMethod = Json.toJSON $ symbolVal (Proxy @method)
    when (gotMethod /= Just wantMethod) $
        throwIO $ UnexpectedResponse gotMethod wantMethod

    let gotMirror = "reflection" `at` json
    when (gotMirror /= Just wantMirror) $
        throwIO $ UnexpectedResponse gotMirror wantMirror

--
-- Exceptions
--

data PeerTerminatedUnexpectedly = PeerTerminatedUnexpectedly deriving Show
instance Exception PeerTerminatedUnexpectedly

data UnexpectedResponse = UnexpectedResponse
    { gotResponse :: Maybe Json.Value
    , expectedResponse :: Json.Value
    } deriving Show
instance Exception UnexpectedResponse
