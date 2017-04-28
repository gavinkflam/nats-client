{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module Network.Nats.Protocol.Tests where

import Hedgehog
import Data.Either
import Network.Nats.Protocol
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Data.ByteString.Char8 as BS

invalidBytes :: [Char]
invalidBytes = " \t\n\r"

genSubjectBytes :: (Monad m, Functor m) => Gen m BS.ByteString
genSubjectBytes =
    BS.intercalate "." <$> (Gen.list (Range.constant 1 5) $ Gen.choice [ Gen.utf8 (Range.constant 1 10) Gen.alphaNum
                                                                       , Gen.utf8 (Range.singleton 1) $ Gen.element (">*" ++ invalidBytes)
                                                                       ])

genSubject :: (Monad m, Functor m) => Gen m Subject
genSubject =
    Subject . (BS.intercalate ".") <$> (Gen.list (Range.constant 1 5) $ Gen.choice [ Gen.utf8 (Range.constant 1 10) Gen.alphaNum
                                                                                   , Gen.utf8 (Range.singleton 1) $ Gen.element ">*"
                                                                                   ])

prop_parseValidSubject :: Property
prop_parseValidSubject =
    withTests 10000 . property $ do
        subjectBytes <- forAll genSubjectBytes
        assert $ case BS.length (BS.filter (\c -> c `elem` invalidBytes) subjectBytes) of
            0 -> isRight (parseSubject subjectBytes)
            _ -> isLeft (parseSubject subjectBytes)

tests :: IO Bool
tests =
    $$(checkConcurrent)