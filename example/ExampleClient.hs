{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Default
import Network.Nats.Client

main :: IO ()
main = do
    conn <- connect connectionSettings
    publish conn (Subject "foo.bar") "test"
    putStrLn $ show conn
    where
        connectionSettings = def ConnectionSettings