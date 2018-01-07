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

parseServerBanner :: BS.ByteString -> Either String NatsServerInfo
parseServerBanner bannerBytes = do
  case A.parseOnly bannerParser bannerBytes of
    Left err         -> Left err
    Right (Banner b) -> eitherDecodeStrict b
    Right a          -> Left $ "Expected server banner, got " ++ (show a)

parseMessage :: MonadThrow m => BS.ByteString -> m Message
parseMessage m =
  case A.parseOnly messageParser m of
    Left  err -> throwM $ MessageParseError err
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
    return $ Subject $ BS.intercalate "." tokens

msgParser :: A.Parser Message
msgParser = do
    _ <- A.string "MSG"
    A.skipSpace
    _subject <- subjectParser
    A.skipSpace
    _subscriptionId <- A.takeTill A.isSpace
    _ <- A.option "" (A.takeTill A.isSpace)
    A.skipSpace
    msgLength <- A.decimal
    A.endOfLine
    payload <- A.take msgLength
    A.endOfLine
    return $ Message payload

okParser :: A.Parser Message
okParser = do
    _ <- A.string "+OK"
    A.endOfLine
    return OKMsg

errorParser :: A.Parser Message
errorParser = do
    _ <- A.string "-ERR"
    A.skipSpace
    err <- A.takeByteString
    A.endOfLine
    return $ ErrorMsg err

pingParser :: A.Parser Message
pingParser = do
    A.string "PING" *> A.endOfLine
    return Ping

messageParser :: A.Parser Message
messageParser = bannerParser <|> msgParser <|> okParser <|> errorParser <|> pingParser
