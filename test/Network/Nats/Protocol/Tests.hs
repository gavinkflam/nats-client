{-# LANGUAGE OverloadedStrings #-}
module Network.Nats.Protocol.Tests where

import Hedgehog
import Data.Either
import Network.Nats.Protocol
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Data.ByteString.Char8 as BS

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

--prop_receiveServerBanner :: Property
--prop_receiveServerBanner =
--  withTests 5000 . property $ do
--  serverBannerBytes <- forAll genServerBannerBytes
--  assert $ 

tests :: IO Bool
tests =
  checkParallel $ Group "Network.Nats.Protocol.Tests" [
  ("prop_parseSubject", prop_parseSubject)
  ]
