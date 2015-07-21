{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | This module provides a *very* basic support for processes with message queues.  It was built using channels and MVars.
module Control.Concurrent.Process (
-- * Types
        ReceiverT, Handle, Process,
-- * Functions
-- ** Process creation / destruction
        makeProcess, runHere, spawn, kill,
-- ** Message passing
        self, sendTo, recv, recvIn, sendRecv
    ) where

import Control.Monad.Reader
import Control.Monad.State.Class
import Control.Monad.Writer.Class
import Control.Monad.Error.Class
import Control.Monad.Catch
import Data.Monoid
import Control.Concurrent
import Control.Applicative

-- | A Process handle.  It's returned on process creation and should be used
-- | afterwards to send messages to it
data Handle r = PH {chan     :: Chan r,
                    thread   :: ThreadId}

-- | The /ReceiverT/ generic type.
--
-- [@r@] the type of things the process will receive
--
-- [@m@] the monad in which it will run
--
-- [@a@] the classic monad parameter
newtype ReceiverT r m a = RT { internalReader :: ReaderT (Handle r) m a }
   deriving (Functor, Applicative, Monad, MonadIO, MonadTrans, MonadCatch, MonadThrow, MonadMask)

-- | /Process/ are receivers that run in the IO Monad
type Process r = ReceiverT r IO

-- | /sendTo/ lets you send a message to a running process. Usage:
-- @
--      sendTo processHandle message
-- @
sendTo :: MonadIO m => Handle a -- ^ The receiver process handle
        -> a                    -- ^ The message to send
        -> m ()
sendTo ph = liftIO . writeChan (chan ph)

-- | /kill/ lets you *brutally* terminate a running process. Usage:
-- @
--      kill processHandle
-- @
kill :: MonadIO m => Handle a -- ^ The handle of process to kill
        -> m ()
kill = liftIO . killThread . thread

-- | /recv/ lets you receive a message in a running process (it's a blocking receive). Usage:
-- @
--      message <- recv
-- @
recv :: MonadIO m => ReceiverT r m r
recv = RT $ ask >>= liftIO . readChan . chan

-- | Just like /recv/ but with a timeout parameter. Usage:
-- @
--      maybeMessage <- recv
-- @
recvIn :: MonadIO m => Int    -- ^ milliseconds to wait until timeout
        -> ReceiverT r m (Maybe r)
recvIn ms = RT $
    do
            ch <- ask >>= return . chan
            liftIO $ do
                        tmp <- newEmptyMVar
                        timer <- if ms > 0
                                    then forkIO $ do
                                                    let its = [1..10] :: [Int]
                                                    forM_ its $ \_ -> threadDelay $ ms * 100
                                                    putMVar tmp Nothing
                                    else forkIO $ putMVar tmp Nothing
                        runner <- forkIO $ readChan ch >>= putMVar tmp . Just
                        res <- takeMVar tmp
                        killThread timer
                        killThread runner
                        return res

-- | /sendRecv/ is just a syntactic sugar for:
-- @
--      sendTo h a >> recv
-- @
sendRecv :: MonadIO m => Handle a -- ^ The receiver process handle
          -> a                    -- ^ The message to send
          -> ReceiverT r m r      -- ^ The process where this action is run will wait until it receives something
sendRecv h a = sendTo h a >> recv

-- | /spawn/ starts a process and returns its handle. Usage:
-- @
--      handle <- spawn process
-- @
spawn :: MonadIO m => Process r k       -- ^ The process to be run
        -> m (Handle r)                 -- ^ The handle for that process
spawn p = liftIO $ do
                 pChan <- newChan
                 pThread <- forkIO $ do
                                         t <- myThreadId
                                         _ <- runReaderT (internalReader p) $ PH pChan t
                                         return ()
                 return $ PH pChan pThread

-- | /runHere/ executes process code in the current environment. Usage:
-- @
--      result <- runHere process
-- @
runHere :: MonadIO m => Process r t     -- ^ The process to be run
         -> m t                         -- ^ It's returned as an action
runHere p = liftIO $ do
                        c <- newChan
                        t <- myThreadId
                        runReaderT (internalReader p) $ PH c t

-- | /self/ returns the handle of the current process. Usage:
-- @
--      handle <- self
-- @
self :: Monad m => ReceiverT r m (Handle r)
self = RT ask

-- | /makeProcess/ builds a process from a code that generates an IO action. Usage:
-- @
--      process <- makeProcess evalFunction receiver
-- @
makeProcess :: (m t -> IO s) -> ReceiverT r m t -> Process r s
makeProcess f (RT a) = RT (mapReaderT f a)

instance MonadState s m => MonadState s (ReceiverT r m) where
    get = lift get
    put = lift . put

instance MonadReader r m => MonadReader r (ReceiverT r m) where
    ask = lift ask
    local = onInner . local

instance (Monoid w, MonadWriter w m) => MonadWriter w (ReceiverT w m) where
    tell = lift . tell
    listen = onInner listen
    pass = onInner pass

instance MonadError e m => MonadError e (ReceiverT r m) where
    throwError = lift . throwError
    catchError (RT a) h = RT $ a `catchError` (\e -> internalReader $ h e)

onInner :: (m a -> m b) -> ReceiverT r m a -> ReceiverT r m b
onInner f (RT m) = RT $ mapReaderT f m
