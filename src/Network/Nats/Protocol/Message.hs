{-|
Module     : Network.Nats.Protocol.Message
Description: Message definitions and utilities for the NATS protocol
-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Nats.Protocol.Message ( Message(..)
                                     , parseMessage
                                     , parseServerBanner
                                     , parseSubject
                                     ) where

import Control.Applicative ((<|>))
import Control.Monad.Catch
import Data.Aeson (eitherDecodeStrict)
import Network.Nats.Protocol.Types
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Char8 as BS

-- | Messages received from the NATS server
data Message = Message BS.ByteString  -- ^ A published message, containing a payload
             | OKMsg                  -- ^ Acknowledgment from server after a client request
             | ErrorMsg BS.ByteString -- ^ Error message from server after a client request
             | Banner BS.ByteString   -- ^ Server "banner" received via an INFO message
             | Ping                   -- ^ Server ping challenge
             deriving Show

-- | Specialized parsed to return a NatsServerInfo
parseServerBanner :: BS.ByteString -> Either String NatsServerInfo
parseServerBanner bannerBytes = do
  case A.parseOnly bannerParser bannerBytes of
    Left err         -> Left err
    Right (Banner b) -> eitherDecodeStrict b
    Right a          -> Left $ "Expected server banner, got " ++ (show a)

-- | Parses a Message from a ByteString
parseMessage :: MonadThrow m => BS.ByteString -> m Message
parseMessage m =
  case A.parseOnly messageParser m of
    Left  err -> throwM $ makeMessageParseError $
      "Reason: " ++ err ++ " Payload: " ++ BS.unpack m
    Right msg -> return msg
  
bannerParser :: A.Parser Message
bannerParser = do
    _ <- A.string "INFO"
    A.skipSpace
    banner <- A.takeByteString
    return $ Banner banner

-- | Parse a 'BS.ByteString' into a 'Subject' or return an error message. See <http://nats.io/documentation/internals/nats-protocol/>
parseSubject :: BS.ByteString -> Either String Subject
parseSubject = A.parseOnly $ subjectParser <* A.endOfInput

-- | The actual parser is quite dumb, it doesn't try to validate silly subjects.
subjectParser :: A.Parser Subject
subjectParser = do
    tokens <- (A.takeWhile1 $ not . A.isSpace) `A.sepBy` (A.char '.')
    return $ makeSubject $ BS.intercalate "." tokens

msgParser :: A.Parser Message
msgParser = do
    _ <- A.string "MSG"
    A.skipSpace
    (_subject, _subscriptionId, _replyTo, msgLength) <-
      msgMetadataParser1 <|> msgMetadataParser2
    payload <- A.take msgLength
    _ <- A.string "\r\n"
    return $ Message payload

msgMetadataParser1
  :: A.Parser (Subject, BS.ByteString, Maybe BS.ByteString, Int)
msgMetadataParser1 = do
    subject <- subjectParser
    subscriptionId <- A.skipSpace >> A.takeTill A.isSpace
    replyTo <- A.skipSpace >> A.takeTill A.isSpace
    msgLength <- A.skipSpace >> A.decimal
    _ <- A.string "\r\n"
    return (subject, subscriptionId, Just replyTo, msgLength)

msgMetadataParser2
  :: A.Parser (Subject, BS.ByteString, Maybe BS.ByteString, Int)
msgMetadataParser2 = do
    subject <- subjectParser
    subscriptionId <- A.skipSpace >> A.takeTill A.isSpace
    msgLength <- A.skipSpace >> A.decimal
    _ <- A.string "\r\n"
    return (subject, subscriptionId, Nothing, msgLength)

okParser :: A.Parser Message
okParser = do
    _ <- A.string "+OK"
    A.endOfLine
    return OKMsg

singleQuoted :: A.Parser BS.ByteString
singleQuoted = do
  _   <- A.char '\''
  str <- A.takeWhile $ \c -> c /= '\''
  _   <- A.char '\''
  return str

errorParser :: A.Parser Message
errorParser = do
    _ <- A.string "-ERR"
    A.skipSpace
    err <- singleQuoted
    A.endOfLine
    return $ ErrorMsg err

pingParser :: A.Parser Message
pingParser = do
    A.string "PING" *> A.endOfLine
    return Ping

messageParser :: A.Parser Message
messageParser = bannerParser <|> msgParser <|> okParser <|> errorParser <|> pingParser
