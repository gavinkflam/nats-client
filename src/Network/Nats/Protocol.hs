{-|
Module      : Network.Nats.Protocol
Description : Implementation of the NATS client protocol
-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Nats.Protocol (
    Connection,
    NatsConnectionOptions,
    NatsServerInfo,
    Subject(..),
    Subscription,
    SubscriptionId(..),
    QueueGroup,
    ProtocolError,
    Message(..),
    defaultConnectionOptions,
    defaultTimeout,
    maxPayloadSize,
    parseSubject, receiveMessage, receiveServerBanner, sendConnect, sendPong, sendPub, sendSub, sendUnsub) where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkFinally)
import Control.Exception
import Control.Exception.Base (SomeException, bracket)
import Control.Monad.Catch
import Control.Monad.IO.Class (liftIO, MonadIO)
import Data.Aeson hiding (Object)
import Data.Aeson.Types (Options(..))
import Data.ByteString.Builder
import Data.ByteString.Lazy (toStrict)
import Data.Default
import Data.Monoid
import Data.Word (Word8)
import Data.Typeable
import GHC.Generics
import System.IO (Handle, hClose)
import System.Log.Logger
import System.Timeout
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T

-- | Server information returned on connection
data NatsServerInfo = NatsServerInfo{ srv_server_id     :: T.Text     -- ^ Server ID
                                    , srv_version       :: T.Text     -- ^ Server version
                                    , srv_go            :: T.Text     -- ^ Version of Go (<https://www.golang.org>) the server was compiled against
                                    , srv_host          :: T.Text     -- ^ Server hostname
                                    , srv_port          :: Int        -- ^ Server port
                                    , srv_auth_required :: Maybe Bool -- ^ Server requires authentication
                                    , srv_ssl_required  :: Maybe Bool -- ^ Server requires SSL connections
                                    , srv_max_payload   :: Int        -- ^ Maximum message payload size accepted by server
                                    }
                                    deriving (Generic, Show)

instance FromJSON NatsServerInfo where
    parseJSON = genericParseJSON defaultOptions{ fieldLabelModifier = stripPrefix "srv_" }
instance ToJSON NatsServerInfo where
    toEncoding = genericToEncoding defaultOptions{ fieldLabelModifier = stripPrefix "srv_" }

-- | Returns the maximum payload size accepted by the server
maxPayloadSize :: NatsServerInfo -> Int
maxPayloadSize = srv_max_payload

-- | Client connection options sent when issuing a "CONNECT" to the server
-- See <http://nats.io/documentation/internals/nats-protocol/>
data NatsConnectionOptions = NatsConnectionOptions{ clnt_verbose      :: Bool   -- ^ Should server reply with an acknowledgment to every message?
                                                  , clnt_pedantic     :: Bool   -- ^ Turn on strict format checking
                                                  , clnt_ssl_required :: Bool   -- ^ Require an SSL connection
                                                  , clnt_name         :: T.Text -- ^ Client name
                                                  , clnt_lang         :: T.Text -- ^ Client implementation language
                                                  , clnt_version      :: T.Text -- ^ Client version
                                                  , clnt_protocol     :: Int    -- ^ Client protocol
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
                                , clnt_protocol     = 1
                                }


-- | Type for representing Queue Groups, used to implement round-robin receivers
newtype QueueGroup = QueueGroup BS.ByteString deriving Show

-- | Type for unexpected protocol errors
data ProtocolError = MessageParseError String -- ^ The message from the server could not be parsed.
    deriving (Show, Typeable)

instance Exception ProtocolError

-- | Connection monad for abstracting away IO
class (Monad m, MonadIO m) => Connection m where
    readBytes  :: Handle -> Int -> m BS.ByteString
    writeBytes :: Handle -> Builder -> m ()
    close      :: Handle -> m ()

instance Connection IO where
    readBytes  = BS.hGetSome
    writeBytes = hPutBuilder
    close      = hClose

-- | Default client connection options, for convenience.
defaultConnectionOptions :: NatsConnectionOptions
defaultConnectionOptions = def NatsConnectionOptions

-- | Default client timeout
defaultTimeout :: Int
defaultTimeout = 1000000

addPrefix :: String -> String -> String
addPrefix prefix = \x -> prefix ++ x

stripPrefix :: String -> String -> String
stripPrefix prefix = drop prefixLength
    where prefixLength = length prefix

-- | Messages received from the NATS server
data Message = Message BS.ByteString  -- ^ A published message, containing a payload
             | OKMsg                  -- ^ Acknowledgment from server after a client request
             | ErrorMsg BS.ByteString -- ^ Error message from server after a client request
             | Banner BS.ByteString   -- ^ Server "banner" received via an INFO message
             | Ping                   -- ^ Server ping challenge
             deriving Show

data Command where
    Connect     :: NatsConnectionOptions -> Command
    Publish     :: Subject -> BS.ByteString -> Command
    Subscribe   :: Subject -> SubscriptionId -> Maybe QueueGroup -> Command
    Unsubscribe :: SubscriptionId -> Maybe Int -> Command
    Pong        :: Command
    deriving (Show)

render :: Command -> Builder
render (Connect opts) =
    stringUtf8 "CONNECT "
    <> lazyByteString (encode opts)
    <> charUtf8 ' '
    <> byteString lineTerminator
render (Publish subject payload) =
    stringUtf8 "PUB "
    <> renderSubject subject
    <> charUtf8 ' '
    <> renderPayload payload
    <> byteString lineTerminator
render (Subscribe subject subId qgroup) =
    stringUtf8 "SUB "
    <> renderSubject subject
    <> charUtf8 ' '
    <> renderSubscriptionId subId
    <> charUtf8 ' '
    <> byteString lineTerminator
render (Unsubscribe subId max_msgs) =
    stringUtf8 "UNSUB "
    <> renderSubscriptionId subId <> charUtf8 ' '
    <> byteString lineTerminator
render Pong =
    stringUtf8 "PONG "
    <> byteString lineTerminator

renderSubject :: Subject -> Builder
renderSubject (Subject s) = byteString s

renderSubscriptionId :: SubscriptionId -> Builder
renderSubscriptionId (SubscriptionId i) = byteString i

renderPayload :: BS.ByteString -> Builder
renderPayload p = intDec (BS.length p) <> byteString lineTerminator <> byteString p

sendCommand :: (Connection m) => Handle -> Command -> m ()
sendCommand sock cmd = do
    r <- liftIO $ timeout defaultTimeout $ writeBytes sock $ render cmd
    case r of
        Nothing -> liftIO $ warningM "Nats.Client.Protocol" $ "Timed out sending command " ++ (show cmd)
        Just _  -> return ()

-- | Receive the initial server banner from an INFO message, or an error message if it cannot be parsed.
receiveServerBanner :: Connection m => Handle -> m (Either String NatsServerInfo)
receiveServerBanner socket = do
    bannerBytes <- readBytes socket maxBytes
    case A.parseOnly bannerParser bannerBytes of
        Left err -> return $ Left err
        Right (Banner b) -> return $ eitherDecodeStrict b
    where maxBytes = 1024

receiveRawMessage :: Connection m => Handle -> Int -> m BS.ByteString
receiveRawMessage sock maxPayloadSize = readBytes sock maxPayloadSize

-- | Receive a 'Message' from the server
receiveMessage :: (MonadThrow m, Connection m) => Handle -> Int -> m Message
receiveMessage sock maxPayloadSize = do
    msg <- receiveRawMessage sock maxPayloadSize
    case A.parseOnly messageParser msg of
        Left  err -> throwM $ MessageParseError err
        Right msg -> return msg

lineTerminator :: BS.ByteString
lineTerminator = "\r\n"

bannerParser :: A.Parser Message
bannerParser = do
    A.string "INFO"
    A.skipSpace
    banner <- A.takeByteString
    return $ Banner banner

-- | Send a "CONNECT" message to the server
sendConnect :: Connection m => Handle -> NatsConnectionOptions -> m ()
sendConnect handle opts = sendCommand handle $ Connect opts

-- | Send a publish request to the server
sendPub :: Connection m => Handle -> Subject -> Int -> BS.ByteString -> m ()
sendPub handle subj payload_len payload = sendCommand handle $ Publish subj payload

-- | Send a Subscription request to a 'Subject', with a 'SubscriptionId' and optionally a 'QueueGroup'.
sendSub :: Connection m => Handle -> Subject -> SubscriptionId -> Maybe QueueGroup -> m ()
sendSub handle subj subId qgroup = sendCommand handle $ Subscribe subj subId qgroup

-- | Send an unsubscription request with a 'SubscriptionId' and optionally a maximum number of messages that will still be listened to.
sendUnsub :: Connection m => Handle -> SubscriptionId -> Maybe Int -> m ()
sendUnsub handle subId max_msgs = sendCommand handle $ Unsubscribe subId max_msgs
 
-- | Send a "PONG" message to the server, typically in reply to a "PING" challenge.
sendPong :: Connection m => Handle -> m ()
sendPong handle = sendCommand handle $ Pong

-- | Name of a NATS subject. Must be a dot-separated alphanumeric string, with ">" and "." as wildcard characters. See <http://nats.io/documentation/internals/nats-protocol/>
newtype Subject = Subject BS.ByteString deriving (Show)

-- | A subscription to a 'Subject'
data Subscription = Subscription { subject        :: Subject
                                 , subscriptionId :: SubscriptionId
                                 }
                    deriving (Show)

-- | A 'Subscription' identifier
newtype SubscriptionId = SubscriptionId BS.ByteString
                    deriving (Show, Ord, Eq)

-- | Parse a 'BS.ByteString' into a 'Subject' or return an error message. See <http://nats.io/documentation/internals/nats-protocol/>
parseSubject :: BS.ByteString -> Either String Subject
parseSubject = A.parseOnly $ subjectParser <* A.endOfInput

subjectParser :: A.Parser Subject
subjectParser = do
    tokens <- (A.takeWhile1 $ not . A.isSpace) `A.sepBy` (A.char '.')
    return $ Subject $ BS.intercalate "." tokens

msgParser :: A.Parser Message
msgParser = do
    A.string "MSG"
    A.skipSpace
    subject <- subjectParser
    A.skipSpace
    subscriptionId <- A.takeTill A.isSpace
    A.option "" (A.takeTill A.isSpace)
    A.skipSpace
    msgLength <- A.decimal
    A.endOfLine
    payload <- A.take msgLength
    A.endOfLine
    return $ Message payload

isEndOfLine_chr :: Char -> Bool
isEndOfLine_chr c = c == '\r'

okParser :: A.Parser Message
okParser = do
    A.string "+OK"
    A.endOfLine
    return OKMsg

errorParser :: A.Parser Message
errorParser = do
    A.string "-ERR"
    A.skipSpace
    error <- A.takeByteString
    A.endOfLine
    return $ ErrorMsg error

pingParser :: A.Parser Message
pingParser = do
    A.string "PING" *> A.endOfLine
    return Ping

messageParser :: A.Parser Message
messageParser = bannerParser <|> msgParser <|> okParser <|> errorParser <|> pingParser
