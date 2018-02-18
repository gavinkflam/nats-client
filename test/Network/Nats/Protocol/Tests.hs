{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
module Network.Nats.Protocol.Tests where

import Hedgehog
import Control.Monad.State
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.ByteString.Builder (toLazyByteString)
import Data.Either
import Data.Monoid ((<>))
import Network.Nats.Protocol
import System.IO (Handle, BufferMode(LineBuffering), hSetBuffering, stdin)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

invalidBytes :: [Char]
invalidBytes = " \t\n\r"

genSubjectBytes :: (MonadGen m, Functor m) => m BS.ByteString
genSubjectBytes =
    BS.intercalate "." <$> (Gen.list (Range.constant 1 5) $ Gen.choice [ Gen.utf8 (Range.constant 1 10) Gen.alphaNum
                                                                       , Gen.utf8 (Range.singleton 1) $ Gen.element (">*" ++ invalidBytes)
                                                                       ])

genSubject :: (MonadGen m, Functor m) => m Subject
genSubject =
    Subject . (BS.intercalate ".") <$> (Gen.list (Range.constant 1 5) $ Gen.choice [ Gen.utf8 (Range.constant 1 10) Gen.alphaNum
                                                                                   , Gen.utf8 (Range.singleton 1) $ Gen.element ">*"
                                                                                   ])

prop_parseSubject :: Property
prop_parseSubject =
  withTests 5000 . property $ do
  subjectBytes <- forAll genSubjectBytes
  assert $ case BS.length (BS.filter (\c -> c `elem` invalidBytes) subjectBytes) of
             0 -> isRight (parseSubject subjectBytes)
             _ -> isLeft (parseSubject subjectBytes)

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

prop_parseServerBanner :: Property
prop_parseServerBanner =
  withTests 5000 . property $ do
  serverInfo <- forAll genNatsServerBannerBytes
  let result = parseServerBanner $ LBS.toStrict serverInfo
  assert $ isRight result

tests :: IO Bool
tests =
  checkSequential $ Group "Network.Nats.Protocol.Tests" [
    ("prop_parseSubject", prop_parseSubject)
  , ("prop_parseServerBanner", prop_parseServerBanner)
  ]
