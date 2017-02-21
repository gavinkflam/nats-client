{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Network.Nats.Client where

import Control.Exception
import Control.Monad.Catch
import Control.Monad.IO.Class
import Data.Default
import Data.Typeable
import GHC.Generics
import Network.Nats.Protocol (NatsServerInfo, receiveServerBanner, sendConnect, sendPub, defaultConnectionOptions, srv_max_payload)
import qualified Data.ByteString.Char8 as BS
import qualified Network.Socket as S hiding (recv)
import qualified Network.Socket.ByteString as SBS

data Connection = Connection{ socket   :: S.Socket
                            , natsInfo :: NatsServerInfo
                            }
                            deriving (Show)

newtype Subject = Subject BS.ByteString

type Host = BS.ByteString
data ConnectionSettings = ConnectionSettings Host S.PortNumber deriving (Show)

data NatsError = ConnectionFailure
               | InvalidServerBanner
               | PayloadTooLarge String
    deriving (Show, Typeable)

instance Exception NatsError

instance Default ConnectionSettings where
    def = ConnectionSettings defaultNatsHost defaultNatsPort

defaultNatsHost :: BS.ByteString
defaultNatsHost = "127.0.0.1"

defaultNatsPort :: S.PortNumber
defaultNatsPort = 4222

connect :: (MonadThrow m, MonadIO m) => ConnectionSettings -> m Connection
connect (ConnectionSettings host port) = liftIO $ S.withSocketsDo $ do
    serverAddr:_ <- S.getAddrInfo Nothing (Just $ BS.unpack host) (Just $ show port)
    sock <- S.socket (S.addrFamily serverAddr) S.Stream S.defaultProtocol
    S.connect sock (S.addrAddress serverAddr)
    natsInfo <- liftIO $ receiveServerBanner sock
    case natsInfo of
        Right info -> do
         sendConnect sock defaultConnectionOptions
         return $ Connection { socket = sock, natsInfo = info }
        Left err   -> throwM InvalidServerBanner

publish :: (MonadThrow m, MonadIO m) => Connection -> Subject -> BS.ByteString -> m ()
publish conn (Subject subj) msg =
    case payload_length > (srv_max_payload (natsInfo conn)) of
        True -> throwM $ PayloadTooLarge $ "Size: " ++ show payload_length ++ ", Max: " ++ show (srv_max_payload (natsInfo conn))
        False -> do
                    liftIO $ sendPub sock subj payload_length msg
    where sock = (socket conn)
          payload_length = BS.length msg

