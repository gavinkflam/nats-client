{-|
Module     : Network.Nats.Protocol.Types
Description: NATS protocol types
-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Nats.Protocol.Types ( makeMessageParseError
                                   , makeSubject
                                   , maxPayloadSize
                                   , NatsServerInfo (..)
                                   , NatsConnectionOptions (..)
                                   , Subject (..)
                                   , Subscription
                                   , SubscriptionId (..)
                                   )
where

import Control.Exception
import Data.Aeson hiding (Object)
import Data.Aeson.Types (Options(..))
import Data.Default
import Data.Typeable
import GHC.Generics
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T

-- | Server information returned on connection
data NatsServerInfo = NatsServerInfo{ _srv_server_id     :: T.Text     -- ^ Server ID
                                    , _srv_version       :: T.Text     -- ^ Server version
                                    , _srv_go            :: T.Text     -- ^ Version of Go (<https://www.golang.org>) the server was compiled against
                                    , _srv_host          :: T.Text     -- ^ Server hostname
                                    , _srv_port          :: Int        -- ^ Server port
                                    , _srv_auth_required :: Maybe Bool -- ^ Server requires authentication
                                    , _srv_ssl_required  :: Maybe Bool -- ^ Server requires SSL connections
                                    , _srv_max_payload   :: Int        -- ^ Maximum message payload size accepted by server
                                    }
                                    deriving (Generic, Show)

instance FromJSON NatsServerInfo where
    parseJSON = genericParseJSON defaultOptions{ fieldLabelModifier = stripPrefix "_srv_" }
instance ToJSON NatsServerInfo where
    toEncoding = genericToEncoding defaultOptions{ fieldLabelModifier = stripPrefix "_srv_" }

-- | Retrieve the maximum payload size, in bytes
maxPayloadSize :: NatsServerInfo -> Int
maxPayloadSize = _srv_max_payload

-- | Client connection options sent when issuing a CONNECT to the server
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

-- | Name of a NATS subject. Must be a dot-separated alphanumeric string, with ">" and "." as wildcard characters. See <http://nats.io/documentation/internals/nats-protocol/>
newtype Subject = Subject BS.ByteString deriving (Show)

-- | Create a Subject with the given ByteString as message
makeSubject :: BS.ByteString -> Subject
makeSubject bs = Subject bs

-- | A subscription to a 'Subject'
data Subscription = Subscription { _subject        :: Subject
                                 , _subscriptionId :: SubscriptionId
                                 }
                    deriving (Show)

-- | A 'Subscription' identifier
newtype SubscriptionId = SubscriptionId BS.ByteString
                    deriving (Show, Ord, Eq)

stripPrefix :: String -> String -> String
stripPrefix prefix = drop prefixLength
    where prefixLength = length prefix

-- | Type for unexpected protocol errors
data ProtocolError = MessageParseError String -- ^ The message from the server could not be parsed.
    deriving (Show, Typeable)

instance Exception ProtocolError

-- | Create MessageParseError with the given reason
makeMessageParseError :: String -> ProtocolError
makeMessageParseError reason = MessageParseError reason
