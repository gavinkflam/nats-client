module Network.Nats.Subscription (Subject(..), Subscription, parseSubject) where

import Data.Word (Word8)
import qualified Data.Attoparsec.ByteString as A
import qualified Data.ByteString.Char8 as BS

