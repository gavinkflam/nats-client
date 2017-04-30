{-|
Module      : Network.Nats.Client
Description : Main interface to the NATS client library
-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Nats.Client (
      defaultConnectionSettings
    , defaultNatsHost
    , defaultNatsPort
    , connect
    , publish
    , subscribe
    , unsubscribe
    , withNats
    , makeSubject
    , ConnectionSettings
    , MessageHandler
    , NatsClient
    , Subject
    , Message (..)
    ) where

import Control.Concurrent (ThreadId, forkFinally)
import Control.Concurrent.MVar
import Control.Exception hiding (catch, bracket)
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.IORef
import Data.Pool
import Data.Typeable
import GHC.Generics
import Network
import Network.Nats.Protocol (
      Connection
    , Subject
    , QueueGroup
    , NatsServerInfo
    , Message(..)
    , Subscription
    , SubscriptionId(..)
    , Subject(..)
    , maxPayloadSize
    , receiveServerBanner
    , sendConnect
    , sendPong
    , sendPub
    , sendSub
    , sendUnsub
    , defaultConnectionOptions
    , parseSubject
    , receiveMessage
    )
import System.IO (Handle, BufferMode(LineBuffering), hClose, hSetBuffering)
import System.Log.Logger
import System.Random
import qualified Data.Map as M
import qualified Data.ByteString.Char8 as BS

-- | A NATS client. See 'connect'.
data NatsClient = NatsClient { connections   :: Pool NatsServerConnection
                             , settings      :: ConnectionSettings
                             , subscriptions :: MVar (M.Map SubscriptionId NatsServerConnection)
                             }

data NatsServerConnection = NatsServerConnection { natsHandle   :: Handle
                                                 , natsInfo     :: NatsServerInfo
                                                 , maxMessages  :: IORef (Maybe Int)
                                                 }

-- | NATS server connection settings
data ConnectionSettings = ConnectionSettings HostName PortID deriving (Show)

-- |'Message' handling function
type MessageHandler = (Message -> IO ())

data NatsError = ConnectionFailure
               | InvalidServerBanner String
               | PayloadTooLarge String
    deriving (Show, Typeable)

instance Exception NatsError

-- | Convenience connection defaults using 'defaultNatsHost' and 'defaultNatsPort'
defaultConnectionSettings :: ConnectionSettings
defaultConnectionSettings = ConnectionSettings defaultNatsHost defaultNatsPort

-- | Default NATS host to connect to
defaultNatsHost :: HostName
defaultNatsHost = "127.0.0.1"

-- | Default port of the NATS server to connect to
defaultNatsPort :: PortID
defaultNatsPort = PortNumber 4222

-- | Convenience default handler for 'Message's
defaultMessageHandler :: Message -> IO ()
defaultMessageHandler msg = return ()

makeNatsServerConnection :: (MonadThrow m, MonadIO m, Connection m) => ConnectionSettings -> m NatsServerConnection
makeNatsServerConnection (ConnectionSettings host port) = do
    h <- liftIO $ connectTo host port
    liftIO $ hSetBuffering h LineBuffering
    natsInfo <- liftIO $ receiveServerBanner h
    liftIO $ debugM "Network.Nats.Client" $ "Received server info " ++ show natsInfo
    case natsInfo of
        Right info -> do
         sendConnect h defaultConnectionOptions
         maxMsgs <- liftIO $ newIORef Nothing
         sub <- liftIO $ newIORef Nothing
         return $ NatsServerConnection { natsHandle = h, natsInfo = info, maxMessages = maxMsgs }
        Left err   -> throwM $ InvalidServerBanner err

destroyNatsServerConnection :: (MonadIO m, Connection m) => NatsServerConnection -> m ()
destroyNatsServerConnection conn = liftIO $ hClose (natsHandle conn)

-- | Connect to a NATS server
connect :: (MonadThrow m, MonadIO m) => ConnectionSettings -> Int -> m NatsClient
connect settings max_connections = do
    connpool <- liftIO $ createPool (makeNatsServerConnection settings) destroyNatsServerConnection 1 60 max_connections
    subs <- liftIO $ newMVar M.empty
    return $ NatsClient { connections = connpool, settings = settings, subscriptions = subs }

-- | Disconnect from a NATS server
disconnect :: (MonadIO m) => NatsClient -> m ()
disconnect conn = liftIO $ destroyAllResources (connections conn)

-- | Perform a computation with a NATS connection
withNats :: (MonadMask m, MonadThrow m, MonadIO m) => ConnectionSettings -> (NatsClient -> m b) -> m b
withNats connectionSettings f = bracket (connect connectionSettings 10) disconnect f

-- | Publish a 'BS.ByteString' to 'Subject'
publish :: (MonadThrow m, MonadIO m, MonadBaseControl IO m) => NatsClient -> Subject -> BS.ByteString -> m ()
publish conn subj msg = withResource (connections conn) $ doPublish subj msg

doPublish :: (MonadThrow m, MonadIO m) => Subject -> BS.ByteString -> NatsServerConnection -> m ()
doPublish subj msg conn = do
    case payload_length > (maxPayloadSize (natsInfo conn)) of
        True  -> throwM $ PayloadTooLarge $ "Size: " ++ show payload_length ++ ", Max: " ++ show (maxPayloadSize (natsInfo conn))
        False -> liftIO $ sendPub sock subj payload_length msg
    where sock = (natsHandle conn)
          payload_length = BS.length msg

-- | Subscribe to a 'Subject' processing 'Message's via a 'MessageHandler'. Returns a 'SubscriptionId' used to cancel subscriptions
subscribe :: (MonadIO m, MonadBaseControl IO m) => NatsClient -> Subject -> MessageHandler -> Maybe QueueGroup -> m SubscriptionId
subscribe conn subj callback qgroup = do
    (c, pool) <- liftIO $ takeResource (connections conn)
    subId <- liftIO $ generateSubscriptionId 5
    let sock        = (natsHandle c)
        max_payload = (maxPayloadSize (natsInfo c))
        maxMsgs     = (maxMessages c)
    liftIO $ sendSub sock subj subId Nothing
    liftIO $ forkFinally (connectionLoop sock max_payload callback maxMsgs) $ handleCompletion sock (connections conn) pool c
    liftIO $ modifyMVarMasked_ (subscriptions conn) $ \m -> return $ M.insert subId c m
    return subId

unsubscribe :: (MonadIO m, MonadBaseControl IO m) => NatsClient -> SubscriptionId -> Maybe Int -> m ()
unsubscribe conn subId msgs@(Just maxMsgs) = do
    liftIO $ withMVarMasked (subscriptions conn) $ \m -> doUnsubscribe m subId maxMsgs
    withResource (connections conn) $ \s -> liftIO $ sendUnsub (natsHandle s) subId msgs
unsubscribe conn subId msgs@Nothing        = do
    liftIO $ withMVarMasked (subscriptions conn) $ \m -> doUnsubscribe m subId 0
    withResource (connections conn) $ \s -> liftIO $ sendUnsub (natsHandle s) subId msgs

doUnsubscribe :: M.Map SubscriptionId NatsServerConnection -> SubscriptionId -> Int -> IO ()
doUnsubscribe m subId maxMsgs = do
    case M.lookup subId m of
        Nothing ->
            warningM "Network.Nats.Client" $ "Could not find subscription " ++ (show subId)
        Just c -> do
            atomicWriteIORef (maxMessages c) (Just maxMsgs)


handleCompletion :: Handle -> Pool NatsServerConnection -> LocalPool NatsServerConnection -> NatsServerConnection -> Either SomeException b -> IO ()
handleCompletion h pool lpool conn (Left exn) = do
    warningM "Network.Nats.Client" $ "Connection closed: " ++ (show exn)
    hClose h
    destroyResource pool lpool conn
handleCompletion h _ lpool conn _          = do
    debugM "Network.Nats.Client" "Subscription finished"
    atomicWriteIORef (maxMessages conn) Nothing
    putResource lpool conn



connectionLoop :: Handle -> Int -> (Message -> IO ()) -> IORef (Maybe Int) -> IO ()
connectionLoop h max_payload f maxMsgsRef = do
    maxMsgs <- readIORef maxMsgsRef
    case maxMsgs of
        Just 0 -> return ()
        _      ->
            receiveMessage h max_payload >>= (\m -> handleMessage h f m maxMsgs) >>= atomicWriteIORef maxMsgsRef >> connectionLoop h max_payload f maxMsgsRef

-- | Attempt to create a 'Subject' from a 'BS.ByteString'
makeSubject :: BS.ByteString -> Either String Subject
makeSubject = parseSubject

generateSubscriptionId :: Int -> IO SubscriptionId
generateSubscriptionId length = do
    gen <- getStdGen
    return $ SubscriptionId $ BS.pack $ take length $ (randoms gen :: [Char])

handleMessage :: Handle -> (Message -> IO ()) -> Message -> Maybe Int -> IO (Maybe Int)
handleMessage h    _ Ping            m = do
    sendPong h
    return m
handleMessage _    f msg@(Message m) maxMsgs = do
    f msg
    case maxMsgs of
        Nothing  -> return Nothing
        (Just n) -> return $ Just (n - 1)
handleMessage _    _ _               m = return m