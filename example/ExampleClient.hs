{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (forever)
import Network.Nats.Client
import qualified Data.ByteString as B

loop :: NatsClient -> Subject -> IO ()
loop client subj = B.getLine >>= publish client subj

main :: IO ()
main = withNats connectionSettings $ \client -> do
    case createSubject "foo.bar.*" of
        Left err -> putStrLn $ "Invalid subject " ++ err
        Right subj -> do
            subId <- subscribe client subj (\(Message m) -> putStrLn $ show m) Nothing
            unsubscribe client subId (Just 5)
            forever $ loop client subj
    where
        connectionSettings = defaultConnectionSettings
