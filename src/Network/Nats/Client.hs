{-|
Module      : Network.Nats.Client
Description : Main interface to the NATS client library
-}
{-# LANGUAGE FlexibleContexts #-}
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
    , createSubject
    , ConnectionSettings(..)
    , MessageHandler
    , NatsClient
    , Subject
    , Message (..)
    ) where

import Control.Concurrent (forkFinally)
import Control.Concurrent.MVar
import Control.Exception hiding (catch, bracket)
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.IORef
import Data.Pool
import Data.Typeable
import Network
import Network.Nats.Protocol
import System.IO (Handle, BufferMode(LineBuffering), hClose, hSetBuffering)
import System.Log.Logger
import System.Random
import System.Timeout
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.ByteString.Char8 as BS

-- | A NATS client. See 'connect'.
data NatsClient = NatsClient { connections   :: Pool NatsServerConnection
                             , settings      :: ConnectionSettings
                             , subscriptions :: MVar (M.Map SubscriptionId NatsServerConnection)
                             , servers       :: MVar (S.Set (HostName, PortNumber))
                             }

data NatsServerConnection = NatsServerConnection { natsHandle   :: Handle
                                                 , natsInfo     :: NatsServerInfo
                                                 , maxMessages  :: IORef (Maybe Int)
                                                 }

-- | NATS server connection settings
data ConnectionSettings = ConnectionSettings { host :: HostName
                                             , port :: PortNumber
                                             } deriving (Show)

-- |'Message' handling function
type MessageHandler = (Message -> IO ())

data NatsError = ConnectionFailure
               | ConnectionTimeout
               | InvalidServerBanner String
               | PayloadTooLarge String
               | UnknownProtocolOperation
               | AttemptedToConnectToRoutePort
               | AuthorizationViolation
               | AuthorizationTimeout
               | InvalidClientProtocol
               | MaximumControlLineExceeded
               | ParserError
               | TLSRequired
               | StaleConnection
               | MaximumConnectionsExceeded
               | SlowConsumer
               | MaximumPayloadViolation
               | InvalidSubject
               | PermissionsViolationForSubscription String
               | PermissionsViolationForPublish String
               | UnknownError String
    deriving (Show, Typeable)

instance Exception NatsError

-- | Convenience connection defaults using 'defaultNatsHost' and 'defaultNatsPort'
defaultConnectionSettings :: ConnectionSettings
defaultConnectionSettings = ConnectionSettings defaultNatsHost defaultNatsPort

-- | Default NATS host to connect to
defaultNatsHost :: HostName
defaultNatsHost = "127.0.0.1"

-- | Default port of the NATS server to connect to
defaultNatsPort :: PortNumber
defaultNatsPort = 4222 :: PortNumber

makeNatsServerConnection :: (MonadThrow m, Connection m) => ConnectionSettings -> MVar (S.Set (HostName, PortNumber)) -> m NatsServerConnection
makeNatsServerConnection (ConnectionSettings ho po) srvs = do
    mh <- liftIO $ timeout defaultTimeout $ connectTo ho $ PortNumber po
    case mh of
        Nothing -> do
            liftIO $ warningM "Network.Nats.Client" $ "Timed out connecting to server: " ++ (show ho) ++ ":" ++ (show po)
            throwM ConnectionTimeout
        Just h  -> do
            liftIO $ hSetBuffering h LineBuffering
            nInfo <- liftIO $ receiveServerBanner h
            liftIO $ infoM "Network.Nats.Client" $ "Received server info " ++ show nInfo
            case nInfo of
                Right info -> do
                    sendConnect h defaultConnectionOptions
                    maxMsgs <- liftIO $ newIORef Nothing
                    _subsc <- liftIO $ newIORef Nothing
                    liftIO $ modifyMVarMasked_ srvs $ \ss -> return $ S.insert (ho, po) ss
                    return $ NatsServerConnection { natsHandle = h, natsInfo = info, maxMessages = maxMsgs }
                Left err   -> throwM $ InvalidServerBanner err

destroyNatsServerConnection :: Connection m => NatsServerConnection -> m ()
destroyNatsServerConnection conn = liftIO $ hClose (natsHandle conn)

-- | Connect to a NATS server
connect :: (MonadThrow m, MonadIO m) => ConnectionSettings -> Int -> m NatsClient
connect s max_connections = do
    srvs <- liftIO $ newMVar S.empty
    connpool <- liftIO $ createPool (makeNatsServerConnection s srvs) destroyNatsServerConnection 1 300 max_connections
    subs <- liftIO $ newMVar M.empty
    return $ NatsClient { connections = connpool, settings = s, subscriptions = subs, servers = srvs }

-- | Disconnect from a NATS server
disconnect :: (MonadIO m) => NatsClient -> m ()
disconnect conn = liftIO $ destroyAllResources (connections conn)

-- | Perform a computation with a NATS connection
withNats :: (MonadMask m, MonadIO m) => ConnectionSettings -> (NatsClient -> m b) -> m b
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
subscribe
    :: MonadIO m
    => NatsClient
    -> Subject
    -> MessageHandler
    -> Maybe QueueGroup
    -> m (SubscriptionId, MVar (Maybe SomeException))
subscribe conn subj callback qgroup = do
    (c, pool) <- liftIO $ takeResource (connections conn)
    subId <- liftIO $ generateSubscriptionId 5
    let sock        = natsHandle c
        max_payload = maxPayloadSize $ natsInfo c
        maxMsgs     = maxMessages c
        loop        = connectionLoop mempty sock max_payload callback maxMsgs
    liftIO $ sendSub sock subj subId qgroup
    mvar <- liftIO newEmptyMVar
    _ <- liftIO $ forkFinally loop $ handleCompletion sock pool c mvar
    liftIO $ modifyMVarMasked_ (subscriptions conn) $
        \m -> return $ M.insert subId c m
    return (subId, mvar)
  where
    handleCompletion h lpool c mvar (Left exn) = do
        hClose h
        destroyResource (connections conn) lpool c
        putMVar mvar $ Just exn
    handleCompletion _ lpool c mvar _          = do
        debugM "Network.Nats.Client" "Subscription finished"
        atomicWriteIORef (maxMessages c) Nothing
        putResource lpool c
        putMVar mvar Nothing

-- | Unsubscribe to a 'SubjectId' (returned by 'subscribe'), with an optional max amount of additional messages to listen to
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

connectionLoop
    :: BS.ByteString
    -> Handle
    -> Int
    -> (Message -> IO ())
    -> IORef (Maybe Int)
    -> IO ()
connectionLoop residual h max_payload f maxMsgsRef = do
    maxMsgs <- readIORef maxMsgsRef
    case maxMsgs of
        Just 0 -> return ()
        _      -> do
            (residual', message) <-
                receiveMessage residual Nothing h max_payload
            count <- handleMessage h f message maxMsgs
            atomicWriteIORef maxMsgsRef count
            connectionLoop residual' h max_payload f maxMsgsRef

-- | Attempt to create a 'Subject' from a 'BS.ByteString'
createSubject :: BS.ByteString -> Either String Subject
createSubject = parseSubject

generateSubscriptionId :: Int -> IO SubscriptionId
generateSubscriptionId idLength = do
    gen <- getStdGen
    return $ SubscriptionId $ BS.pack $ take idLength $ (randoms gen :: [Char])

handleMessage
    :: (MonadThrow m, MonadIO m)
    => Handle -> (Message -> IO ()) -> Message -> Maybe Int -> m (Maybe Int)
handleMessage h    _ Ping            m = do
    liftIO $ sendPong h
    return m
handleMessage _    f msg@(Message _) maxMsgs = do
    liftIO $ f msg
    case maxMsgs of
        Nothing  -> return Nothing
        (Just n) -> return $ Just (n - 1)
handleMessage _    _ (ErrorMsg errorMessage) _ =
    throw $ parseErrorMessage errorMessage
  where
    parseErrorMessage "Authorization Violation"          =
        AuthorizationViolation
    parseErrorMessage "Authorization Timeout"            =
        AuthorizationTimeout
    parseErrorMessage "Invalid Client Protocol"          =
        InvalidClientProtocol
    parseErrorMessage "Maximum Control Line Exceeded"    =
        MaximumControlLineExceeded
    parseErrorMessage "Parser Error"                     =
        ParserError
    parseErrorMessage "Secure Connection - TLS Required" =
        TLSRequired
    parseErrorMessage "Stale Connection"                 =
        StaleConnection
    parseErrorMessage "Maximum Connections Exceeded"     =
        MaximumConnectionsExceeded
    parseErrorMessage "Slow Consumer"                    =
        SlowConsumer
    parseErrorMessage "Maximum Payload Violation"        =
        MaximumPayloadViolation
    parseErrorMessage "Invalid Subject"                  =
        InvalidSubject
    parseErrorMessage _
        | BS.isPrefixOf subPermissionsViolationPrefix errorMessage =
            PermissionsViolationForSubscription $ BS.unpack $ snd $
                BS.breakSubstring subPermissionsViolationPrefix errorMessage
        | BS.isPrefixOf subPermissionsViolationPrefix errorMessage =
            PermissionsViolationForPublish $ BS.unpack $ snd $
                BS.breakSubstring pubPermissionsViolationPrefix errorMessage
        | otherwise = UnknownError $ BS.unpack errorMessage
    subPermissionsViolationPrefix = "Permissions Violation for Subscription to "
    pubPermissionsViolationPrefix = "Permissions Violation for Publish to "
handleMessage _    _ msg               m = do
    liftIO $ warningM "Network.Nats.Client" $ "Received " ++ show msg
    return m
