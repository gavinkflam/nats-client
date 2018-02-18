{-# LANGUAGE OverloadedStrings #-}
module Network.Nats.Test.Generators where

import Hedgehog
import Data.Aeson
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Semigroup ((<>))
import Network.Nats.Protocol.Types
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

invalidBytes :: [Char]
invalidBytes = " \t\n\r"

genValidSubjectBytes :: (MonadGen m, Functor m) => m BS.ByteString
genValidSubjectBytes =
  BS.intercalate "." <$> (Gen.list (Range.constant 1 5) $ Gen.utf8 (Range.constant 1 10) $ Gen.choice [ Gen.alphaNum, Gen.element (">*") ])

genInvalidSubjectBytes :: (MonadGen m, Functor m) => m BS.ByteString
genInvalidSubjectBytes =
    BS.intercalate "." <$> (Gen.list (Range.constant 1 5) $ Gen.utf8 (Range.singleton 1) $ Gen.element (">*" ++ invalidBytes))

genSubjectBytes :: (MonadGen m, Functor m) => m BS.ByteString
genSubjectBytes =
  Gen.choice [ genValidSubjectBytes
             , genInvalidSubjectBytes
             ]

genSubject :: (MonadGen m, Functor m) => m Subject
genSubject =
    Subject . (BS.intercalate ".") <$> (Gen.list (Range.constant 1 5) $ Gen.choice [ Gen.utf8 (Range.constant 1 10) Gen.alphaNum
                                                                                   , Gen.utf8 (Range.singleton 1) $ Gen.element ">*"
                                                                                   ])

genSubscriptionIdBytes :: (MonadGen m, Functor m) => m BS.ByteString
genSubscriptionIdBytes =
  Gen.utf8 (Range.constant 1 100) Gen.alphaNum

genNatsServerInfo :: (MonadGen m, Functor m) => m NatsServerInfo
genNatsServerInfo =
  NatsServerInfo
  <$> Gen.text (Range.constant 1 10) Gen.alphaNum
  <*> Gen.text (Range.constant 1 10) Gen.alphaNum
  <*> Gen.text (Range.constant 1 10) Gen.alphaNum
  <*> Gen.text (Range.constant 1 10) Gen.alphaNum
  <*> Gen.int (Range.constant 0 65535)
  <*> Gen.maybe Gen.bool
  <*> Gen.maybe Gen.bool
  <*> Gen.int (Range.constant 0 1000000)

genNatsServerBannerBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genNatsServerBannerBytes = do
  nsi <- genNatsServerInfo
  return $ LBS.append (LBS.pack "INFO ") (encode nsi)

spaceBuilder :: Builder
spaceBuilder = charUtf8 ' '

eolBuilder :: Builder
eolBuilder = byteString "\r\n"

singleQuoteBuilder :: Builder
singleQuoteBuilder = charUtf8 '\''

genMessageMsgBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genMessageMsgBytes = do
  msg <- Gen.bytes (Range.constant 1 1024)
  subj <- genValidSubjectBytes
  subs <- genSubscriptionIdBytes
  return $ toLazyByteString $
    stringUtf8 "MSG"
    <> spaceBuilder
    <> byteString subj
    <> spaceBuilder
    <> byteString subs
    <> spaceBuilder
    <> intDec (BS.length msg)
    <> eolBuilder
    <> byteString msg
    <> eolBuilder

genOkMsgBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genOkMsgBytes = return $ toLazyByteString $
  stringUtf8 "+OK"
  <> eolBuilder

genErrorMsgBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genErrorMsgBytes = do
  err <- Gen.list (Range.constant 1 1024) Gen.alphaNum
  return $ toLazyByteString $
    stringUtf8 "-ERR"
    <> spaceBuilder
    <> singleQuoteBuilder
    <> stringUtf8 err
    <> singleQuoteBuilder
    <> eolBuilder

genPingMsgBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genPingMsgBytes = return $ toLazyByteString $
  stringUtf8 "PING"
  <> eolBuilder

genMessageBytes :: (MonadGen m, Functor m) => m LBS.ByteString
genMessageBytes =
  Gen.choice [ genMessageMsgBytes
             , genOkMsgBytes
             , genErrorMsgBytes
             , genPingMsgBytes
             , genNatsServerBannerBytes
             ]
