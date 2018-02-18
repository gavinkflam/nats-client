{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
module Network.Nats.Protocol.Tests where

import Hedgehog
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Either
import Network.Nats.Protocol
import Network.Nats.Test.Generators

prop_parseSubject :: Property
prop_parseSubject =
  withTests 5000 . property $ do
  subjectBytes <- forAll genSubjectBytes
  assert $ case BS.length (BS.filter (\c -> c `elem` invalidBytes) subjectBytes) of
             0 -> isRight (parseSubject subjectBytes)
             _ -> isLeft (parseSubject subjectBytes)

prop_parseServerBanner :: Property
prop_parseServerBanner =
  withTests 5000 . property $ do
  serverInfo <- forAll genNatsServerBannerBytes
  let result = parseServerBanner $ LBS.toStrict serverInfo
  assert $ isRight result

prop_parseMessage :: Property
prop_parseMessage =
  withTests 5000 . property $ do
  msg <- forAll genMessageBytes
  _ <- evalM $ parseMessage $ LBS.toStrict msg
  success

tests :: IO Bool
tests =
  checkSequential $ Group "Network.Nats.Protocol.Tests" [
    ("prop_parseSubject", prop_parseSubject)
  , ("prop_parseServerBanner", prop_parseServerBanner)
  , ("prop_parseMessage", prop_parseMessage)
  ]
