{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}

-- | Vector conversions and utilities.

module System.IO.Streams.Vector
 ( -- * Vector conversions
   fromVector
 , toVector
 , outputToVector
 , toMutableVector
 , outputToMutableVector
 , writeVector

   -- * Utility
 , chunkVector
 , vectorOutputStream
 , mutableVectorOutputStream
 ) where

------------------------------------------------------------------------------
import           Control.Concurrent.MVar     (modifyMVar, modifyMVar_, newMVar)
import           Control.Monad               (liftM, (>=>))
import           Control.Monad.IO.Class      (MonadIO (..))
import           Control.Monad.Primitive     (PrimState (..))
import           Data.IORef                  (IORef, newIORef, readIORef,
                                              writeIORef)
import           Data.Vector.Generic         (Vector (..))
import qualified Data.Vector.Generic         as V
import           Data.Vector.Generic.Mutable (MVector)
import qualified Data.Vector.Generic.Mutable as VM
import           System.IO.Streams.Internal  (InputStream, OutputStream,
                                              Sink (..), fromGenerator,
                                              nullSink, sinkToStream, yield)
import qualified System.IO.Streams.Internal  as S


------------------------------------------------------------------------------
-- | Transforms a vector into an 'InputStream' that yields each of the values
-- in the vector in turn.
fromVector :: Vector v a => v a -> IO (InputStream a)
fromVector = fromGenerator . V.mapM_ yield
{-# INLINE fromVector #-}


------------------------------------------------------------------------------
-- | Drains an 'InputStream', converting it to a vector. N.B. that this
-- function reads the entire 'InputStream' strictly into memory and as such is
-- not recommended for streaming applications or where the size of the input is
-- not bounded or known.
toVector :: Vector v a => InputStream a -> IO (v a)
toVector = toMutableVector >=> V.basicUnsafeFreeze
{-# INLINE toVector #-}


------------------------------------------------------------------------------
-- | Drains an 'InputStream', converting it to a mutable vector. N.B. that this
-- function reads the entire 'InputStream' strictly into memory and as such is
-- not recommended for streaming applications or where the size of the input is
-- not bounded or known.
toMutableVector :: VM.MVector v a => InputStream a -> IO (v (PrimState IO) a)
toMutableVector input = vfNew initialSize >>= go
  where
    initialSize = 64

    go vfi = S.read input >>= maybe (vfFinish vfi) (vfAdd vfi >=> go)
{-# INLINE toMutableVector #-}


------------------------------------------------------------------------------
-- | 'vectorOutputStream' returns an 'OutputStream' which stores values fed
-- into it and an action which flushes all stored values to a vector.
--
-- The flush action resets the store.
--
-- Note that this function /will/ buffer any input sent to it on the heap.
-- Please don't use this unless you're sure that the amount of input provided
-- is bounded and will fit in memory without issues.
vectorOutputStream :: Vector v c => IO (OutputStream c, IO (v c))
vectorOutputStream = do
    (os, flush) <- mutableVectorOutputStream
    return $! (os, flush >>= V.basicUnsafeFreeze)
{-# INLINE vectorOutputStream #-}


------------------------------------------------------------------------------
data VectorFillInfo v c = VectorFillInfo {
      _vec :: !(v (PrimState IO) c)
    , _idx :: {-# UNPACK #-} !(IORef Int)
    , _sz  :: {-# UNPACK #-} !(IORef Int)
    }


------------------------------------------------------------------------------
vfNew :: MVector v a => Int -> IO (VectorFillInfo v a)
vfNew initialSize = do
    v  <- VM.unsafeNew initialSize
    i  <- newIORef 0
    sz <- newIORef initialSize
    return $! VectorFillInfo v i sz


------------------------------------------------------------------------------
vfFinish :: MVector v a =>
            VectorFillInfo v a
         -> IO (v (PrimState IO) a)
vfFinish (VectorFillInfo v i _) = liftM (flip VM.unsafeTake v) $ readIORef i


------------------------------------------------------------------------------
vfAdd :: MVector v a =>
         VectorFillInfo v a
      -> a
      -> IO (VectorFillInfo v a)
vfAdd vfi@(VectorFillInfo v iRef szRef) !x = do
    i  <- readIORef iRef
    sz <- readIORef szRef
    if i < sz then add i else grow sz
  where
    add i = do
        VM.unsafeWrite v i x
        writeIORef iRef $! i + 1
        return vfi

    grow sz = do
        let !sz' = sz * 2
        v' <- VM.unsafeGrow v sz
        writeIORef szRef sz'
        vfAdd (vfi { _vec = v' }) x


------------------------------------------------------------------------------
-- | 'mutableVectorOutputStream' returns an 'OutputStream' which stores values
-- fed into it and an action which flushes all stored values to a vector.
--
-- The flush action resets the store.
--
-- Note that this function /will/ buffer any input sent to it on the heap.
-- Please don't use this unless you're sure that the amount of input provided
-- is bounded and will fit in memory without issues.
mutableVectorOutputStream :: VM.MVector v c =>
                             IO (OutputStream c, IO (v (PrimState IO) c))
mutableVectorOutputStream = do
    r <- vfNew 32 >>= newMVar
    c <- sinkToStream $ consumer r
    return (c, flush r)

  where
    consumer r = go
      where
        go = Sink $ maybe (return nullSink)
                          (\c -> do
                               modifyMVar_ r $ flip vfAdd c
                               return go)
    flush r = modifyMVar r $ \vfi -> do
                                !v   <- vfFinish vfi
                                vfi' <- vfNew 32
                                return $! (vfi', v)
{-# INLINE mutableVectorOutputStream #-}


------------------------------------------------------------------------------
-- | Given an IO action that requires an 'OutputStream', creates one and
-- captures all the output the action sends to it as a mutable vector.
--
-- Example:
--
-- @
-- ghci> import "Control.Applicative"
-- ghci> import qualified "Data.Vector" as V
-- ghci> ('connect' \<\$\> 'System.IO.Streams.fromList' [1, 2, 3::'Int'])
--        \>\>= 'outputToMutableVector'
--        \>\>= V.'Data.Vector.freeze'
-- fromList [1,2,3]
-- @
outputToMutableVector :: MVector v a =>
                         (OutputStream a -> IO b)
                      -> IO (v (PrimState IO) a)
outputToMutableVector f = do
    (os, getVec) <- mutableVectorOutputStream
    _ <- f os
    getVec
{-# INLINE outputToMutableVector #-}


------------------------------------------------------------------------------
-- | Given an IO action that requires an 'OutputStream', creates one and
-- captures all the output the action sends to it as a vector.
--
-- Example:
--
-- @
-- ghci> import "Control.Applicative"
-- ghci> (('connect' <$> 'System.IO.Streams.fromList' [1, 2, 3]) >>= 'outputToVector')
--           :: IO ('Data.Vector.Vector' Int)
-- fromList [1,2,3]
-- @
outputToVector :: Vector v a => (OutputStream a -> IO b) -> IO (v a)
outputToVector = outputToMutableVector >=> V.basicUnsafeFreeze
{-# INLINE outputToVector #-}


------------------------------------------------------------------------------
-- | Splits an input stream into chunks of at most size @n@.
--
-- Example:
--
-- @
-- ghci> ('System.IO.Streams.fromList' [1..14::Int] >>= 'chunkVector' 4 >>= 'System.IO.Streams.toList')
--          :: IO ['Data.Vector.Vector' Int]
-- [fromList [1,2,3,4],fromList [5,6,7,8],fromList [9,10,11,12],fromList [13,14]]
-- @
chunkVector :: Vector v a => Int -> InputStream a -> IO (InputStream (v a))
chunkVector n input = if n <= 0
                        then error $ "chunkVector: bad size: " ++ show n
                        else vfNew n >>= fromGenerator . go n
  where
    doneChunk !vfi = do
        liftIO (vfFinish vfi >>= V.unsafeFreeze) >>= yield
        !vfi' <- liftIO $ vfNew n
        go n vfi'

    go !k !vfi | k <= 0    = doneChunk vfi
               | otherwise = liftIO (S.read input) >>= maybe finish chunk
      where
        finish = do
            v <- liftIO (vfFinish vfi >>= V.unsafeFreeze)
            if V.null v then return $! () else yield v

        chunk x = do
            !vfi' <- liftIO $ vfAdd vfi x
            go (k - 1) vfi'
{-# INLINE chunkVector #-}


------------------------------------------------------------------------------
-- | Feeds a vector to an 'OutputStream'. Does /not/ write an end-of-stream to
-- the stream.
writeVector :: Vector v a => v a -> OutputStream a -> IO ()
writeVector v out = V.mapM_ (flip S.write out . Just) v
{-# INLINE writeVector #-}
