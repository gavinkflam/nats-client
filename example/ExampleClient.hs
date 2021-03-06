{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Monad (forever)
import Network.Nats.Client
import qualified Data.ByteString as B

loop :: NatsClient -> Subject -> IO ()
loop client subj = B.getLine >>= publish client subj

main :: IO ()
main = withNats connectionSettings $ \client ->
    case createSubject "foo.*" of
        Left err -> putStrLn $ "Invalid subject " ++ err
        Right subj -> do
            (subId, _) <- subscribe client subj
                (\m -> putStrLn $ "RECV: " ++ show m) Nothing
            unsubscribe client subId (Just 90)
            forever $ loop client subj
    where
        connectionSettings = defaultConnectionSettings { host = "demo.nats.io" }
