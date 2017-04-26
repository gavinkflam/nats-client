module Main where

import Control.Monad (unless)
import System.Exit (exitFailure)
import System.IO (BufferMode(..), hSetBuffering, stdout, stderr)
import qualified Network.Nats.Protocol.Tests

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering

    results <- sequence [ Network.Nats.Protocol.Tests.tests
                        ]

    unless (and results) exitFailure