{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-|
Module      : Network.Nats.Protocol
Description : Implementation of the NATS client protocol
-}
{-# LANGUAGE DeriveGeneric #-}
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
    maxPayloadSize,
    parseSubject, receiveMessage, receiveServerBanner, sendConnect, sendPong, sendPub, sendSub, sendUnsub) where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkFinally)
import Control.Exception
import Control.Exception.Base (SomeException, bracket)
import Control.Monad.Catch
import Control.Monad.IO.Class (liftIO)
import Data.Aeson hiding (Object)
import Data.Aeson.Types (Options(..))
import Data.ByteString.Builder
import Data.ByteString.Lazy (toStrict)
import Data.Default
import Data.Monoid
import Data.Word (Word8)
import Data.Typeable
import GHC.Generics
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import qualified Network.Socket as S hiding (send, recv)
import qualified Network.Socket.ByteString as SBS

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


-- | Type for representing Queue Groups, used to implement round-robin receivers
newtype QueueGroup = QueueGroup BS.ByteString

-- | Type for unexpected protocol errors
data ProtocolError = MessageParseError String -- ^ The message from the server could not be parsed.
    deriving (Show, Typeable)

instance Exception ProtocolError

-- | Connection monad for abstracting away IO
class Monad m => Connection m where
    readBytes  :: S.Socket -> Int -> m BS.ByteString
    writeBytes :: S.Socket -> BS.ByteString -> m Int
    close      :: S.Socket -> m ()

instance Connection IO where
    readBytes  = SBS.recv
    writeBytes = SBS.send
    close      = S.close

-- | Default client connection options, for convenience.
defaultConnectionOptions :: NatsConnectionOptions
defaultConnectionOptions = def NatsConnectionOptions

addPrefix :: String -> String -> String
addPrefix prefix = \x -> prefix ++ x

stripPrefix :: String -> String -> String
stripPrefix prefix = drop prefixLength
    where prefixLength = length prefix

-- | Messages received from the NATS server
data Message = Message BS.ByteString  -- ^ A published message, containing a payload
             | OKMsg                  -- ^ Acknowledgment from server after a client request
             | ErrorMsg BS.ByteString -- ^ Error message frrom server after a client request
             | Banner BS.ByteString   -- ^ Server "banner" received via an INFO message
             | Ping                   -- ^ Server ping challenge
             deriving Show

data Command where
    Connect :: NatsConnectionOptions -> Command
    Publish :: Subject -> BS.ByteString -> Command

render :: Command -> Builder
render (Connect opts) = stringUtf8 "CONNECT " <> lazyByteString (encode opts) <> charUtf8 ' ' <> byteString lineTerminator
render (Publish subject payload) = stringUtf8 "PUB " <> renderSubject subject <> charUtf8 ' ' <> renderPayload payload <> byteString lineTerminator

renderSubject :: Subject -> Builder
renderSubject (Subject s) = byteString s

renderPayload :: BS.ByteString -> Builder
renderPayload p = intDec (BS.length p) <> byteString lineTerminator <> byteString p

-- | Receive the initial server banner from an INFO message, or an error message if it cannot be parsed.
receiveServerBanner :: Connection m => S.Socket -> m (Either String NatsServerInfo)
receiveServerBanner socket = do
    bannerBytes <- readBytes socket maxBytes
    
    case A.parseOnly bannerParser bannerBytes of
        Left err -> return $ Left err
        Right (Banner b) -> return $ eitherDecodeStrict b
    where maxBytes = 1024

receiveRawMessage :: Connection m => S.Socket -> Int -> m BS.ByteString
receiveRawMessage sock maxPayloadSize = readBytes sock maxPayloadSize

-- | Receive a 'Message' from the server
receiveMessage :: (MonadThrow m, Connection m) => S.Socket -> Int -> m Message
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

doSend :: Connection m => S.Socket -> BS.ByteString -> m Int
doSend sock msg = writeBytes sock msg

-- | Send a "CONNECT" message to the server
sendConnect :: Connection m => S.Socket -> NatsConnectionOptions -> m ()
sendConnect sock opts = do
    bytesSent <- doSend sock connectionString
    return ()
    where connectionString = BS.concat ["CONNECT ", toStrict $ encode opts, lineTerminator]

-- | Send a publish request to the server
sendPub :: Connection m => S.Socket -> Subject -> Int -> BS.ByteString -> m ()
sendPub sock (Subject subj) payload_len payload = do
    bytesSent <- doSend sock msg
    return ()
    where msg = BS.concat ["PUB ", subj, " ", BS.pack $ show payload_len, lineTerminator, payload, lineTerminator]

-- | Send a Subscription request to a 'Subject', with a 'SubscriptionId' and optionally a 'QueueGroup'.
sendSub :: Connection m => S.Socket -> Subject -> SubscriptionId -> Maybe QueueGroup -> m ()
sendSub sock (Subject subj) (SubscriptionId subId) qgroup = do
    bytesSent <- doSend sock msg
    return ()
    where msg = BS.concat ["SUB ", subj, " ", subId, lineTerminator]

-- | Send an unsubscription request with a 'SubscriptionId' and optionally a maximum number of messages that will still be listened to.
sendUnsub :: Connection m => S.Socket -> SubscriptionId -> Maybe Int -> m ()
sendUnsub sock (SubscriptionId subId) max_msgs = do
    let msg = case max_msgs of
                Just m  -> BS.concat ["UNSUB ", subId, BS.pack $ show m, lineTerminator]
                Nothing -> BS.concat ["UNSUB ", subId, lineTerminator]
    bytesSent <- doSend sock msg
    return ()

-- | Send a "PONG" message to the server, typically in reply to a "PING" challenge.
sendPong :: Connection m => S.Socket -> m ()
sendPong sock = do
    bytesSent <- doSend sock msg
    return ()
    where msg = BS.concat ["PONG", lineTerminator]

sendNatsMsg :: Connection m => S.Socket -> BS.ByteString -> m ()
sendNatsMsg sock msg = doSend sock msg >> return ()

-- | Name of a NATS subject. Must be a dot-separated alphanumeric string, with ">" and "." as wildcard characters. See <http://nats.io/documentation/internals/nats-protocol/>
newtype Subject = Subject BS.ByteString deriving (Show)

-- | A subscription to a 'Subject'
data Subscription = Subscription { subject :: Subject
                                 }
                    deriving (Show)

-- | A 'Subscription' identifier
newtype SubscriptionId = SubscriptionId BS.ByteString

-- | Parse a 'BS.ByteString' into a 'Subject' or return an error message. See <http://nats.io/documentation/internals/nats-protocol/>
parseSubject :: BS.ByteString -> Either String Subject
parseSubject = A.parseOnly $ subjectParser <* A.endOfInput

subjectParser :: A.Parser Subject
subjectParser = do
    tokens <- (A.takeWhile A.isSpace) `A.sepBy` (A.char '.')
    subj <- A.takeTill A.isSpace
    return $ Subject subj

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
