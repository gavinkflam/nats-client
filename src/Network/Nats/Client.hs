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
import Data.Pool
import Data.Typeable
import GHC.Generics
import Network.Nats.Protocol (Connection, Subject, QueueGroup, NatsServerInfo, Message(..), Subscription, SubscriptionId(..), Subject(..), maxPayloadSize, receiveServerBanner, sendConnect, sendPub, sendSub, sendPong, defaultConnectionOptions, parseSubject, receiveMessage)
import System.Log.Logger
import System.Random
import qualified Data.ByteString.Char8 as BS
import qualified Network.Socket as S hiding (recv)
import qualified Network.Socket.ByteString as SBS

-- | A NATS client. See 'connect'.
data NatsClient = NatsClient { connections :: Pool NatsServerConnection
                             , settings    :: ConnectionSettings
                             }

data NatsServerConnection = NatsServerConnection { socket   :: S.Socket
                                                 , natsInfo :: NatsServerInfo
                                                 }

type Host = BS.ByteString

-- | NATS server connection settings
data ConnectionSettings = ConnectionSettings Host S.PortNumber deriving (Show)

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
defaultNatsHost :: BS.ByteString
defaultNatsHost = "127.0.0.1"

-- | Default port of the NATS server to connect to
defaultNatsPort :: S.PortNumber
defaultNatsPort = 4222

-- | Convenience default handler for 'Message's
defaultMessageHandler :: Message -> IO ()
defaultMessageHandler msg = return ()

makeNatsServerConnection :: (MonadThrow m, MonadIO m, Connection m) => ConnectionSettings -> m NatsServerConnection
makeNatsServerConnection settings = do
    (sock, serverAddr) <- liftIO $ createSocket settings
    liftIO $ S.connect sock (S.addrAddress serverAddr)
    natsInfo <- liftIO $ receiveServerBanner sock
    case natsInfo of
        Right info -> do
         sendConnect sock defaultConnectionOptions
         return $ NatsServerConnection { socket = sock, natsInfo = info }
        Left err   -> throwM $ InvalidServerBanner err

destroyNatsServerConnection :: (MonadIO m, Connection m) => NatsServerConnection -> m ()
destroyNatsServerConnection conn = liftIO $ S.close (socket conn)

-- | Connect to a NATS server
connect :: (MonadThrow m, MonadIO m) => ConnectionSettings -> Int -> m NatsClient
connect settings max_connections = do
    connpool <- liftIO $ createPool (makeNatsServerConnection settings) destroyNatsServerConnection 1 60 max_connections
    return $ NatsClient { connections = connpool, settings = settings }

-- | Disconnect from a NATS server
disconnect :: (MonadIO m) => NatsClient -> m ()
disconnect conn = liftIO $ destroyAllResources (connections conn)

createSocket :: ConnectionSettings -> IO (S.Socket, S.AddrInfo)
createSocket (ConnectionSettings host port) = do
    serverAddr:_ <- S.getAddrInfo Nothing (Just $ BS.unpack host) (Just $ show port)
    sock <- S.socket (S.addrFamily serverAddr) S.Stream S.defaultProtocol
    return (sock, serverAddr)

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
    where sock = (socket conn)
          payload_length = BS.length msg

-- | Subscribe to a 'Subject' processing 'Message's via a 'MessageHandler'. Returns a 'SubscriptionId' used to cancel subscriptions
subscribe :: (MonadIO m, MonadBaseControl IO m) => NatsClient -> Subject -> MessageHandler -> Maybe QueueGroup -> m SubscriptionId
subscribe conn subj callback qgroup = do
    (c, pool) <- liftIO $ takeResource (connections conn)
    subId <- liftIO $ generateSubscriptionId 5
    let sock        = (socket c)
        max_payload = (maxPayloadSize (natsInfo c))
    liftIO $ sendSub sock subj subId Nothing
    liftIO $ forkFinally (connectionLoop sock max_payload callback) $ handleCompletion sock pool c
    return subId

--unsubscribe :: (MonadIO m) -> SubscriptionId -> Maybe Int -> m ()
--unsubscribe

handleCompletion :: S.Socket -> LocalPool NatsServerConnection -> NatsServerConnection -> Either SomeException b -> IO ()
handleCompletion sock pool conn (Left exn) = do
    warningM "Network.Nats.Client" $ "Connection closed: " ++ (show exn)
    S.close sock
    putResource pool conn
handleCompletion sock pool conn _          = do
    warningM "Network.Nats.Client" "Connection ended unexpectedly"
    S.close sock
    putResource pool conn

connectionLoop :: S.Socket -> Int -> (Message -> IO ()) -> IO ()
connectionLoop sock max_payload f = do
    receiveMessage sock max_payload >>= handleMessage sock f
    connectionLoop sock max_payload f

-- | Attempt to create a 'Subject' from a 'BS.ByteString'
makeSubject :: BS.ByteString -> Either String Subject
makeSubject = parseSubject

generateSubscriptionId :: Int -> IO SubscriptionId
generateSubscriptionId length = do
    gen <- getStdGen
    return $ SubscriptionId $ BS.pack $ take length $ (randoms gen :: [Char])

handleMessage :: S.Socket -> (Message -> IO ()) -> Message -> IO ()
handleMessage sock _ Ping            = sendPong sock
handleMessage _    f msg@(Message m) = f msg
handleMessage _    _ _               = return ()