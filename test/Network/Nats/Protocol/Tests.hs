{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Network.Nats.Protocol.Tests where

import Hedgehog
import Data.Either
import Network.Nats.Protocol
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Data.ByteString.Char8 as BS

genValidSubjectBytes :: (Monad m, Functor m) => Gen m BS.ByteString
genValidSubjectBytes = do
    BS.intercalate "." <$> Gen.list (Range.constant 1 5) (Gen.utf8 (Range.constant 1 10) Gen.alpha)

prop_parseValidSubject :: Property
prop_parseValidSubject =
    withTests 5000 . property $ do
        subjectBytes <- forAll genValidSubjectBytes
        assert $ isRight (parseSubject subjectBytes)


tests :: IO Bool
tests =
    $$(checkConcurrent)