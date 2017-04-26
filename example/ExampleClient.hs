{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (forever)
import Network.Nats.Client
import qualified Data.ByteString as B

loop :: NatsClient -> Subject -> IO ()
loop client subj = B.getLine >>= publish client subj

main :: IO ()
main = withNats connectionSettings $ \client -> do
    case makeSubject "foo.bar" of
        Left err -> putStrLn err
        Right subj -> do
            subscribe client subj (\(Message m) -> putStrLn $ show m) Nothing
            forever $ loop client subj
    where
        connectionSettings = defaultConnectionSettings