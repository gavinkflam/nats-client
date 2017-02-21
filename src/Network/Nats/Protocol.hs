{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
module Network.Nats.Protocol where

import Data.Aeson hiding (Object)
import Data.Aeson.Types (Options(..))
import Data.Default
import Data.Word (Word8)
import GHC.Generics
import Data.ByteString.Lazy (toStrict)
import qualified Data.Attoparsec.ByteString as A
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import qualified Network.Socket as S hiding (send, recv)
import qualified Network.Socket.ByteString as SBS

data NatsServerInfo = NatsServerInfo{ srv_server_id     :: T.Text
                                    , srv_version       :: T.Text
                                    , srv_go            :: T.Text
                                    , srv_host          :: T.Text
                                    , srv_port          :: Int
                                    , srv_auth_required :: Maybe Bool
                                    , srv_ssl_required  :: Maybe Bool
                                    , srv_max_payload   :: Int
                                    }
                                    deriving (Generic, Show)

instance FromJSON NatsServerInfo where
    parseJSON = genericParseJSON defaultOptions{ fieldLabelModifier = stripPrefix "srv_" }
instance ToJSON NatsServerInfo where
    toEncoding = genericToEncoding defaultOptions{ fieldLabelModifier = stripPrefix "srv_" }

data NatsConnectionOptions = NatsConnectionOptions{ clnt_verbose      :: Bool
                                                  , clnt_pedantic     :: Bool
                                                  , clnt_ssl_required :: Bool
                                                  , clnt_name         :: T.Text
                                                  , clnt_lang         :: T.Text
                                                  , clnt_version      :: T.Text
                                                  }
                                                  deriving (Generic, Show)

instance FromJSON NatsConnectionOptions where
    parseJSON = genericParseJSON defaultOptions{ fieldLabelModifier = stripPrefix "clnt_" }
instance ToJSON NatsConnectionOptions where
    toEncoding = genericToEncoding defaultOptions{ fieldLabelModifier = stripPrefix "clnt_" }

instance Default NatsConnectionOptions where
    def = NatsConnectionOptions { clnt_verbose      = False
                                , clnt_pedantic     = False
                                , clnt_ssl_required = False
                                , clnt_name         = ""
                                , clnt_lang         = "haskell"
                                , clnt_version      = "0.1.0"
                                }

defaultConnectionOptions :: NatsConnectionOptions
defaultConnectionOptions = def NatsConnectionOptions

addPrefix :: String -> String -> String
addPrefix prefix = \x -> prefix ++ x

stripPrefix :: String -> String -> String
stripPrefix prefix = drop prefixLength
    where prefixLength = length prefix


receiveServerBanner :: S.Socket -> IO (Either String NatsServerInfo)
receiveServerBanner socket = do
    banner <- SBS.recv socket maxBytes
    putStrLn $ show (BS.unpack banner)
    return $ ((A.parseOnly bannerParser banner) >>= eitherDecodeStrict :: Either String NatsServerInfo)
    where maxBytes = 1024

isWhiteSpace :: Word8 -> Bool
isWhiteSpace w = w == 20

bannerParser :: A.Parser BS.ByteString
bannerParser = do
    A.string "INFO"
    A.takeWhile isWhiteSpace
    A.takeByteString

doSend :: S.Socket -> BS.ByteString -> IO Int
doSend sock msg = SBS.send sock msg

sendConnect :: S.Socket -> NatsConnectionOptions -> IO ()
sendConnect sock opts = do
    bytesSent <- doSend sock connectionString
    return ()
    where connectionString = BS.pack $ "CONNECT " ++ (BS.unpack . toStrict $ encode opts) ++ "\r\n"


sendPub :: S.Socket -> BS.ByteString -> Int -> BS.ByteString -> IO ()
sendPub sock subj payload_len payload = do
    bytesSent <- doSend sock msg
    return ()
    where msg = BS.pack $ "PUB " ++ BS.unpack subj ++ " " ++ show payload_len ++ "\r\n" ++ BS.unpack payload ++ "\r\n"