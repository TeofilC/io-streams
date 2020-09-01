-- | Generic stream manipulations

{-# LANGUAGE BangPatterns       #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes         #-}

module System.IO.Streams.Combinators
 ( -- * Folds
   inputFoldM
 , outputFoldM
 , fold
 , foldM
 , fold_
 , foldM_
 , any
 , all
 , maximum
 , minimum

   -- * Unfolds
 , unfoldM

   -- * Maps
 , map
 , mapM
 , mapM_
 , mapMaybe
 , contramap
 , contramapM
 , contramapM_
 , contramapMaybe

   -- * Filter
 , filter
 , filterM
 , filterOutput
 , filterOutputM

   -- * Takes and drops
 , give
 , take
 , drop
 , ignore

   -- * Zip and unzip
 , zip
 , zipWith
 , zipWithM
 , unzip
 , contraunzip

   -- * Utility
 , intersperse
 , skipToEof
 , ignoreEof
 , atEndOfInput
 , atEndOfOutput
 ) where

------------------------------------------------------------------------------
import           Control.Concurrent.MVar    (newMVar, withMVar)
import           Control.Monad              (liftM, void, when)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Int                   (Int64)
import           Data.IORef                 (IORef, atomicModifyIORef, modifyIORef, newIORef, readIORef, writeIORef)
import           Data.Maybe                 (isJust)
import           Prelude                    hiding (all, any, drop, filter, map, mapM, mapM_, maximum, minimum, read, take, unzip, zip, zipWith)
------------------------------------------------------------------------------
import           System.IO.Streams.Internal (InputStream (..), OutputStream (..), fromGenerator, makeInputStream, makeOutputStream, read, unRead, write, yield)


------------------------------------------------------------------------------
-- | A side-effecting fold over an 'OutputStream', as a stream transformer.
--
-- The IO action returned by 'outputFoldM' can be used to fetch and reset the updated
-- seed value. Example:
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3::Int]
-- ghci> (os, getList) <- Streams.'System.IO.Streams.List.listOutputStream'
-- ghci> (os', getSeed) \<- Streams.'outputFoldM' (\\x y -> return (x+y)) 0 os
-- ghci> Streams.'System.IO.Streams.connect' is os'
-- ghci> getList
-- [1,2,3]
-- ghci> getSeed
-- 6
-- @
outputFoldM :: (a -> b -> IO a)           -- ^ fold function
            -> a                          -- ^ initial seed
            -> OutputStream b             -- ^ output stream
            -> IO (OutputStream b, IO a)  -- ^ returns a new stream as well as
                                          -- an IO action to fetch and reset the
                                          --  updated seed value.
outputFoldM f initial stream = do
    ref <- newIORef initial
    os  <- makeOutputStream (wr ref)
    return (os, fetch ref)

  where
    wr _ Nothing       = write Nothing stream
    wr ref mb@(Just x) = do
        !z  <- readIORef ref
        !z' <- f z x
        writeIORef ref z'
        write mb stream

    fetch ref = atomicModifyIORef ref $ \x -> (initial, x)


------------------------------------------------------------------------------
-- | A side-effecting fold over an 'InputStream', as a stream transformer.
--
-- The IO action returned by 'inputFoldM' can be used to fetch and reset the updated seed
-- value. Example:
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3::Int]
-- ghci> (is', getSeed) \<- Streams.'inputFoldM' (\\x y -> return (x+y)) 0 is
-- ghci> Streams.'System.IO.Streams.List.toList' is'
-- [1,2,3]
-- ghci> getSeed
-- 6
-- @
inputFoldM :: (a -> b -> IO a)          -- ^ fold function
           -> a                         -- ^ initial seed
           -> InputStream b             -- ^ input stream
           -> IO (InputStream b, IO a)  -- ^ returns a new stream as well as an
                                        -- IO action to fetch and reset the
                                        -- updated seed value.
inputFoldM f initial stream = do
    ref <- newIORef initial
    is  <- makeInputStream (rd ref)
    return (is, fetch ref)

  where
    twiddle _ Nothing = return Nothing

    twiddle ref mb@(Just x) = do
        !z  <- readIORef ref
        !z' <- f z x
        writeIORef ref z'
        return mb

    rd ref = read stream >>= twiddle ref

    fetch ref = atomicModifyIORef ref $ \x -> (initial, x)


------------------------------------------------------------------------------
-- | A left fold over an input stream. The input stream is fully consumed. See
-- 'Prelude.foldl'.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [1..10] >>= Streams.'fold' (+) 0
-- 55
-- @
fold :: (s -> a -> s)       -- ^ fold function
     -> s                   -- ^ initial seed
     -> InputStream a       -- ^ input stream
     -> IO s
fold f seed stream = go seed
  where
    go !s = read stream >>= maybe (return s) (go . f s)


------------------------------------------------------------------------------
-- | A side-effecting left fold over an input stream. The input stream is fully
-- consumed. See 'Prelude.foldl'.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [1..10] >>= Streams.'foldM' (\x y -> 'return' (x + y)) 0
-- 55
-- @
foldM :: (s -> a -> IO s)       -- ^ fold function
      -> s                      -- ^ initial seed
      -> InputStream a          -- ^ input stream
      -> IO s
foldM f seed stream = go seed
  where
    go !s = read stream >>= maybe (return s) ((go =<<) . f s)


------------------------------------------------------------------------------
-- | A variant of 'System.IO.Streams.fold' suitable for use with composable folds
-- from \'beautiful folding\' libraries like
-- <http://hackage.haskell.org/package/foldl the foldl library>.
-- The input stream is fully consumed. 
--
-- Example:
--
-- @
-- ghci> let folds = liftA3 (,,) Foldl.length Foldl.mean Foldl.maximum
-- ghci> Streams.'System.IO.Streams.fromList' [1..10::Double] >>= Foldl.purely Streams.'System.IO.Streams.fold_' folds is
-- ghci> (10,5.5,Just 10.0)
-- @
--
-- /Since 1.3.6.0/
--
fold_ :: (x -> a -> x)    -- ^ accumulator update function
      -> x                -- ^ initial seed
      -> (x -> s)         -- ^ recover folded value
      -> InputStream a    -- ^ input stream
      -> IO s
fold_ op seed done stream = liftM done (go seed)
   where 
     go !s = read stream >>= maybe (return s) (go . op s)


------------------------------------------------------------------------------
-- | A variant of 'System.IO.Streams.foldM' suitable for use with composable folds
-- from \'beautiful folding\' libraries like
-- <http://hackage.haskell.org/package/foldl the foldl library>.
-- The input stream is fully consumed. 
--
-- Example:
--
-- @
-- ghci> let folds = Foldl.mapM_ print *> Foldl.generalize (liftA2 (,) Foldl.sum Foldl.mean)
-- ghci> Streams.'System.IO.Streams.fromList' [1..3::Double] >>= Foldl.impurely Streams.'System.IO.Streams.foldM_' folds
-- 1.0
-- 2.0
-- 3.0
-- (6.0,2.0)
-- @
--
-- /Since 1.3.6.0/
--
foldM_ :: (x -> a -> IO x)   -- ^ accumulator update action
       -> IO x               -- ^ initial seed
       -> (x -> IO s)        -- ^ recover folded value
       -> InputStream a      -- ^ input stream
       -> IO s
foldM_ f seed done stream = seed >>= go 
  where
    go !x = read stream >>= maybe (done x) ((go =<<) . f x)


------------------------------------------------------------------------------
-- | @any predicate stream@ returns 'True' if any element in @stream@ matches
-- the predicate.
--
-- 'any' consumes as few elements as possible, ending consumption if an element
-- satisfies the predicate.
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3]
-- ghci> Streams.'System.IO.Streams.Combinators.any' (> 0) is    -- Consumes one element
-- True
-- ghci> Streams.'System.IO.Streams.read' is
-- Just 2
-- ghci> Streams.'System.IO.Streams.Combinators.any' even is     -- Only 3 remains
-- False
-- @
any :: (a -> Bool) -> InputStream a -> IO Bool
any predicate stream = go
  where
    go = do
        mElem <- read stream
        case mElem of
            Nothing -> return False
            Just e  -> if predicate e then return True else go


------------------------------------------------------------------------------
-- | @all predicate stream@ returns 'True' if every element in @stream@ matches
-- the predicate.
--
-- 'all' consumes as few elements as possible, ending consumption if any element
-- fails the predicate.
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3]
-- ghci> Streams.'System.IO.Streams.Combinators.all' (< 0) is    -- Consumes one element
-- False
-- ghci> Streams.'System.IO.Streams.read' is
-- Just 2
-- ghci> Streams.'System.IO.Streams.Combinators.all' odd is      -- Only 3 remains
-- True
-- @
all :: (a -> Bool) -> InputStream a -> IO Bool
all predicate stream = go
  where
    go = do
        mElem <- read stream
        case mElem of
            Nothing -> return True
            Just e  -> if predicate e then go else return False


------------------------------------------------------------------------------
-- | @maximum stream@ returns the greatest element in @stream@ or 'Nothing' if
-- the stream is empty.
--
-- 'maximum' consumes the entire stream.
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3]
-- ghci> Streams.'System.IO.Streams.Combinators.maximum' is
-- 3
-- ghci> Streams.'System.IO.Streams.read' is     -- The stream is now empty
-- Nothing
-- @
maximum :: (Ord a) => InputStream a -> IO (Maybe a)
maximum stream = do
    mElem0 <- read stream
    case mElem0 of
        Nothing -> return Nothing
        Just e  -> go e
  where
    go oldElem = do
        mElem <- read stream
        case mElem of
            Nothing      -> return (Just oldElem)
            Just newElem -> go (max oldElem newElem)


------------------------------------------------------------------------------
-- | @minimum stream@ returns the greatest element in @stream@
--
-- 'minimum' consumes the entire stream.
--
-- @
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [1, 2, 3]
-- ghci> Streams.'System.IO.Streams.Combinators.minimum' is
-- 1
-- ghci> Streams.'System.IO.Streams.read' is    -- The stream is now empty
-- Nothing
-- @
minimum :: (Ord a) => InputStream a -> IO (Maybe a)
minimum stream = do
    mElem0 <- read stream
    case mElem0 of
        Nothing -> return Nothing
        Just e  -> go e
  where
    go oldElem = do
        mElem <- read stream
        case mElem of
            Nothing      -> return (Just oldElem)
            Just newElem -> go (min oldElem newElem)


------------------------------------------------------------------------------
-- | @unfoldM f seed@ builds an 'InputStream' from successively applying @f@ to
-- the @seed@ value, continuing if @f@ produces 'Just' and halting on
-- 'Nothing'.
--
-- @
-- ghci> is \<- Streams.'System.IO.Streams.Combinators.unfoldM' (\n -> return $ if n < 3 then Just (n, n + 1) else Nothing) 0
-- ghci> Streams.'System.IO.Streams.List.toList' is
-- [0,1,2]
-- @
unfoldM :: (b -> IO (Maybe (a, b))) -> b -> IO (InputStream a)
unfoldM f seed = fromGenerator (go seed)
  where
    go oldSeed = do
       m <- liftIO (f oldSeed)
       case m of
           Nothing           -> return $! ()
           Just (a, newSeed) -> do
               yield a
               go newSeed

------------------------------------------------------------------------------
-- | Maps a pure function over an 'InputStream'.
--
-- @map f s@ passes all output from @s@ through the function @f@.
--
-- Satisfies the following laws:
--
-- @
-- Streams.'map' (g . f) === Streams.'map' f >=> Streams.'map' g
-- Streams.'map' 'id' === Streams.'makeInputStream' . Streams.'read'
-- @
map :: (a -> b) -> InputStream a -> IO (InputStream b)
map f s = makeInputStream g
  where
    g = read s >>= return . fmap f


------------------------------------------------------------------------------
-- | Maps an impure function over an 'InputStream'.
--
-- @mapM f s@ passes all output from @s@ through the IO action @f@.
--
-- Satisfies the following laws:
--
-- @
-- Streams.'mapM' (f >=> g) === Streams.'mapM' f >=> Streams.'mapM' g
-- Streams.'mapM' 'return' === Streams.'makeInputStream' . Streams.'read'
-- @
--
mapM :: (a -> IO b) -> InputStream a -> IO (InputStream b)
mapM f s = makeInputStream g
  where
    g = do
        mb <- read s >>= maybe (return Nothing)
                               (\x -> liftM Just $ f x)

        return mb


------------------------------------------------------------------------------
-- | Maps a side effect over an 'InputStream'.
--
-- @mapM_ f s@ produces a new input stream that passes all output from @s@
-- through the side-effecting IO action @f@.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [1,2,3] >>=
--       Streams.'mapM_' ('putStrLn' . 'show' . (*2)) >>=
--       Streams.'System.IO.Streams.toList'
-- 2
-- 4
-- 6
-- [1,2,3]
-- @
--
mapM_ :: (a -> IO b) -> InputStream a -> IO (InputStream a)
mapM_ f s = makeInputStream $ do
    mb <- read s
    _  <- maybe (return $! ()) (void . f) mb
    return mb


------------------------------------------------------------------------------
-- | A version of map that discards elements
--
-- @mapMaybe f s@ passes all output from @s@ through the function @f@ and
-- discards elements for which @f s@ evaluates to 'Nothing'.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [Just 1, None, Just 3] >>=
--       Streams.'mapMaybe' 'id' >>=
--       Streams.'System.IO.Streams.toList'
-- [1,3]
-- @
--
-- /Since: 1.2.1.0/
mapMaybe :: (a -> Maybe b) -> InputStream a -> IO (InputStream b)
mapMaybe f src = makeInputStream g
  where
    g = do
      s <- read src
      case s of
        Nothing -> return Nothing
        Just x ->
          case f x of
            Nothing -> g
            y -> return y
------------------------------------------------------------------------------
-- | Contravariant counterpart to 'map'.
--
-- @contramap f s@ passes all input to @s@ through the function @f@.
--
-- Satisfies the following laws:
--
-- @
-- Streams.'contramap' (g . f) === Streams.'contramap' g >=> Streams.'contramap' f
-- Streams.'contramap' 'id' === 'return'
-- @
contramap :: (a -> b) -> OutputStream b -> IO (OutputStream a)
contramap f s = makeOutputStream $ flip write s . fmap f


------------------------------------------------------------------------------
-- | Contravariant counterpart to 'mapM'.
--
-- @contramapM f s@ passes all input to @s@ through the IO action @f@
--
-- Satisfies the following laws:
--
-- @
-- Streams.'contramapM' (f >=> g) = Streams.'contramapM' g >=> Streams.'contramapM' f
-- Streams.'contramapM' 'return' = 'return'
-- @
contramapM :: (a -> IO b) -> OutputStream b -> IO (OutputStream a)
contramapM f s = makeOutputStream g
  where
    g Nothing = write Nothing s

    g (Just x) = do
        !y <- f x
        write (Just y) s


------------------------------------------------------------------------------
-- | Equivalent to 'mapM_' for output.
--
-- @contramapM f s@ passes all input to @s@ through the side-effecting IO
-- action @f@.
--
contramapM_ :: (a -> IO b) -> OutputStream a -> IO (OutputStream a)
contramapM_ f s = makeOutputStream $ \mb -> do
    _ <- maybe (return $! ()) (void . f) mb
    write mb s


------------------------------------------------------------------------------
-- | Contravariant counterpart to 'contramapMaybe'.
--
-- @contramap f s@ passes all input to @s@ through the function @f@.
-- Discards all the elements for which @f@ returns 'Nothing'.
--
-- /Since: 1.2.1.0/
--
contramapMaybe :: (a -> Maybe b) -> OutputStream b -> IO (OutputStream a)
contramapMaybe f s = makeOutputStream $ g
    where
      g Nothing = write Nothing s
      g (Just a) =
        case f a of
          Nothing -> return ()
          x -> write x s


------------------------------------------------------------------------------
-- | Drives an 'InputStream' to end-of-stream, discarding all of the yielded
-- values.
skipToEof :: InputStream a -> IO ()
skipToEof str = go
  where
    go = read str >>= maybe (return $! ()) (const go)
{-# INLINE skipToEof #-}


------------------------------------------------------------------------------
-- | Drops chunks from an input stream if they fail to match a given filter
-- predicate. See 'Prelude.filter'.
--
-- Items pushed back to the returned stream are propagated back upstream.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [\"the\", \"quick\", \"brown\", \"fox\"] >>=
--       Streams.'filterM' ('return' . (/= \"brown\")) >>= Streams.'System.IO.Streams.toList'
-- [\"the\",\"quick\",\"fox\"]
-- @
filterM :: (a -> IO Bool)
        -> InputStream a
        -> IO (InputStream a)
filterM p src = return $! InputStream prod pb
  where
    prod = read src >>= maybe eof chunk

    chunk s = do
        b <- p s
        if b then return $! Just s
             else prod

    eof = return Nothing

    pb s = unRead s src


------------------------------------------------------------------------------
-- | Drops chunks from an input stream if they fail to match a given filter
-- predicate. See 'Prelude.filter'.
--
-- Items pushed back to the returned stream are propagated back upstream.
--
-- Example:
--
-- @
-- ghci> Streams.'System.IO.Streams.fromList' [\"the\", \"quick\", \"brown\", \"fox\"] >>=
--       Streams.'filter' (/= \"brown\") >>= Streams.'System.IO.Streams.toList'
-- [\"the\",\"quick\",\"fox\"]
-- @
filter :: (a -> Bool)
       -> InputStream a
       -> IO (InputStream a)
filter p src = return $! InputStream prod pb
  where
    prod = read src >>= maybe eof chunk

    chunk s = do
        let b = p s
        if b then return $! Just s
             else prod

    eof  = return Nothing
    pb s = unRead s src


------------------------------------------------------------------------------
-- | The function @intersperse v s@ wraps the 'OutputStream' @s@, creating a
-- new output stream that writes its input to @s@ interspersed with the
-- provided value @v@. See 'Data.List.intersperse'.
--
-- Example:
--
-- @
-- ghci> import Control.Monad ((>=>))
-- ghci> is <- Streams.'System.IO.Streams.List.fromList' [\"nom\", \"nom\", \"nom\"::'ByteString']
-- ghci> Streams.'System.IO.Streams.List.outputToList' (Streams.'intersperse' \"burp!\" >=> Streams.'System.IO.Streams.connect' is)
-- [\"nom\",\"burp!\",\"nom\",\"burp!\",\"nom\"]
-- @
intersperse :: a -> OutputStream a -> IO (OutputStream a)
intersperse sep os = newIORef False >>= makeOutputStream . f
  where
    f _ Nothing = write Nothing os
    f sendRef s    = do
        b <- readIORef sendRef
        writeIORef sendRef True
        when b $ write (Just sep) os
        write s os


------------------------------------------------------------------------------
-- | Combines two input streams. Continues yielding elements from both input
-- streams until one of them finishes.
zip :: InputStream a -> InputStream b -> IO (InputStream (a, b))
zip src1 src2 = makeInputStream src
  where
    src = read src1 >>= (maybe (return Nothing) $ \a ->
            read src2 >>= (maybe (unRead a src1 >> return Nothing) $ \b ->
              return $! Just $! (a, b)))


------------------------------------------------------------------------------
-- | Combines two input streams using the supplied function. Continues yielding
-- elements from both input streams until one of them finishes.
zipWith :: (a -> b -> c)
        -> InputStream a
        -> InputStream b
        -> IO (InputStream c)
zipWith f src1 src2 = makeInputStream src
  where
    src = read src1 >>= (maybe (return Nothing) $ \a ->
            read src2 >>= (maybe (unRead a src1 >> return Nothing) $ \b ->
              return $! Just $! f a b ) )


------------------------------------------------------------------------------
-- | Combines two input streams using the supplied monadic function. Continues
-- yielding elements from both input streams until one of them finishes.
zipWithM :: (a -> b -> IO c)
         -> InputStream a
         -> InputStream b
         -> IO (InputStream c)
zipWithM f src1 src2 = makeInputStream src
  where
    src = read src1 >>= (maybe (return Nothing) $ \a ->
            read src2 >>= (maybe (unRead a src1 >> return Nothing) $ \b ->
              f a b >>= \c -> return $! Just $! c ) )


------------------------------------------------------------------------------
-- | Filters output to be sent to the given 'OutputStream' using a pure
-- function. See 'filter'.
--
-- Example:
--
-- @
-- ghci> import qualified "Data.ByteString.Char8" as S
-- ghci> os1 \<- Streams.'System.IO.Streams.stdout' >>= Streams.'System.IO.Streams.unlines
-- ghci> os2 \<- os1 >>= Streams.'contramap' (S.pack . show) >>= Streams.'filterOutput' even
-- ghci> Streams.'write' (Just 3) os2
-- ghci> Streams.'write' (Just 4) os2
-- 4
-- @
{- Note: The example is a lie, because unlines has weird behavior -}
filterOutput :: (a -> Bool) -> OutputStream a -> IO (OutputStream a)
filterOutput p output = makeOutputStream chunk
  where
    chunk Nothing  = write Nothing output
    chunk ch@(Just x) = when (p x) $ write ch output


------------------------------------------------------------------------------
-- | Filters output to be sent to the given 'OutputStream' using a predicate
-- function in IO. See 'filterM'.
--
-- Example:
--
-- @
-- ghci> let check a = putStrLn a ("Allow " ++ show a ++ "?") >> readLn :: IO Bool
-- ghci> import qualified Data.ByteString.Char8 as S
-- ghci> os1 <- Streams.'System.IO.Streams.unlines' Streams.'System.IO.Streams.stdout'
-- ghci> os2 \<- os1 >>= Streams.'contramap' (S.pack . show) >>= Streams.'filterOutputM' check
-- ghci> Streams.'System.IO.Streams.write' (Just 3) os2
-- Allow 3?
-- False\<Enter>
-- ghci> Streams.'System.IO.Streams.write' (Just 4) os2
-- Allow 4?
-- True\<Enter>
-- 4
-- @
filterOutputM :: (a -> IO Bool) -> OutputStream a -> IO (OutputStream a)
filterOutputM p output = makeOutputStream chunk
  where
    chunk Nothing  = write Nothing output
    chunk ch@(Just x) = do
        b <- p x
        if b then write ch output else return $! ()


------------------------------------------------------------------------------
-- | Takes apart a stream of pairs, producing a pair of input streams. Reading
-- from either of the produced streams will cause a pair of values to be pulled
-- from the original stream if necessary. Note that reading @n@ values from one
-- of the returned streams will cause @n@ values to be buffered at the other
-- stream.
--
-- Access to the original stream is thread safe, i.e. guarded by a lock.
unzip :: forall a b . InputStream (a, b) -> IO (InputStream a, InputStream b)
unzip os = do
    lock <- newMVar $! ()
    buf1 <- newIORef id
    buf2 <- newIORef id

    is1  <- makeInputStream $ src1 lock buf1 buf2
    is2  <- makeInputStream $ src2 lock buf1 buf2

    return (is1, is2)

  where
    twist (a,b) = (b,a)

    src1 lock aBuf bBuf = withMVar lock $ const $ do
        dl <- readIORef aBuf
        case dl [] of
          []     -> more os id bBuf
          (x:xs) -> writeIORef aBuf (xs++) >> (return $! Just x)

    src2 lock aBuf bBuf = withMVar lock $ const $ do
        dl <- readIORef bBuf
        case dl [] of
          []     -> more os twist aBuf
          (y:ys) -> writeIORef bBuf (ys++) >> (return $! Just y)

    more :: forall a b x y .
            InputStream (a,b)
         -> ((a,b) -> (x,y))
         -> IORef ([y] -> [y])
         -> IO (Maybe x)
    more origs proj buf = read origs >>=
                          maybe (return Nothing)
                                (\x -> do
                                    let (a, b) = proj x
                                    modifyIORef buf (. (b:))
                                    return $! Just a)


------------------------------------------------------------------------------
-- | Given two 'OutputStream's, returns a new stream that "unzips" the tuples
-- being written, writing the two elements to the corresponding given streams.
--
-- You can use this together with @'contramap' (\\ x -> (x, x))@ to "fork" a
-- stream into two.
--
-- /Since: 1.5.2.0/
contraunzip :: OutputStream a -> OutputStream b -> IO (OutputStream (a, b))
contraunzip sink1 sink2 = makeOutputStream $ \ tuple -> do
    write (fmap fst tuple) sink1
    write (fmap snd tuple) sink2


------------------------------------------------------------------------------
-- | Wraps an 'InputStream', producing a new 'InputStream' that will produce at
-- most @n@ items, subsequently yielding end-of-stream forever.
--
-- Items pushed back to the returned 'InputStream' will be propagated upstream,
-- modifying the count of taken items accordingly.
--
-- Example:
--
-- @
-- ghci> is <- Streams.'fromList' [1..9::Int]
-- ghci> is' <- Streams.'take' 1 is
-- ghci> Streams.'read' is'
-- Just 1
-- ghci> Streams.'read' is'
-- Nothing
-- ghci> Streams.'System.IO.Streams.peek' is
-- Just 2
-- ghci> Streams.'unRead' 11 is'
-- ghci> Streams.'System.IO.Streams.peek' is
-- Just 11
-- ghci> Streams.'System.IO.Streams.peek' is'
-- Just 11
-- ghci> Streams.'read' is'
-- Just 11
-- ghci> Streams.'read' is'
-- Nothing
-- ghci> Streams.'read' is
-- Just 2
-- ghci> Streams.'toList' is
-- [3,4,5,6,7,8,9]
-- @
--
take :: Int64 -> InputStream a -> IO (InputStream a)
take k0 input = do
    kref <- newIORef k0
    return $! InputStream (prod kref) (pb kref)
  where
    prod kref = do
        !k <- readIORef kref
        if k <= 0
          then return Nothing
          else do
              m <- read input
              when (isJust m) $ modifyIORef kref $ \x -> x - 1
              return m

    pb kref !s = do
       unRead s input
       modifyIORef kref (+1)


------------------------------------------------------------------------------
-- | Wraps an 'InputStream', producing a new 'InputStream' that will drop the
-- first @n@ items produced by the wrapped stream. See 'Prelude.drop'.
--
-- Items pushed back to the returned 'InputStream' will be propagated upstream,
-- modifying the count of dropped items accordingly.
drop :: Int64 -> InputStream a -> IO (InputStream a)
drop k0 input = do
    kref <- newIORef k0
    return $! InputStream (prod kref) (pb kref)
  where
    prod kref = do
        !k <- readIORef kref
        if k <= 0
          then getInput kref
          else discard kref

    getInput kref = do
        read input >>= maybe (return Nothing) (\c -> do
            modifyIORef kref (\x -> x - 1)
            return $! Just c)

    discard kref = getInput kref >>= maybe (return Nothing) (const $ prod kref)

    pb kref s = do
        unRead s input
        modifyIORef kref (+1)


------------------------------------------------------------------------------
-- | Wraps an 'OutputStream', producing a new 'OutputStream' that will pass at
-- most @n@ items on to the wrapped stream, subsequently ignoring the rest of
-- the input.
--
give :: Int64 -> OutputStream a -> IO (OutputStream a)
give k output = newIORef k >>= makeOutputStream . chunk
  where
    chunk ref = maybe (return $! ()) $ \x -> do
                    !n <- readIORef ref
                    if n <= 0
                      then return $! ()
                      else do
                          writeIORef ref $! n - 1
                          write (Just x) output


------------------------------------------------------------------------------
-- | Wraps an 'OutputStream', producing a new 'OutputStream' that will ignore
-- the first @n@ items received, subsequently passing the rest of the input on
-- to the wrapped stream.
--
ignore :: Int64 -> OutputStream a -> IO (OutputStream a)
ignore k output = newIORef k >>= makeOutputStream . chunk
  where
    chunk ref = maybe (return $! ()) $ \x -> do
                    !n <- readIORef ref
                    if n > 0
                      then writeIORef ref $! n - 1
                      else write (Just x) output


------------------------------------------------------------------------------
-- | Wraps an 'OutputStream', ignoring any end-of-stream 'Nothing' values
-- written to the returned stream.
--
-- /Since: 1.0.1.0/
--
ignoreEof :: OutputStream a -> IO (OutputStream a)
ignoreEof s = return $ OutputStream f
  where
    f Nothing  = return $! ()
    f x        = write x s


------------------------------------------------------------------------------
-- | Wraps an 'InputStream', running the specified action when the stream
-- yields end-of-file.
--
-- /Since: 1.0.2.0/
--
atEndOfInput :: IO b -> InputStream a -> IO (InputStream a)
atEndOfInput m is = return $! InputStream prod pb
  where
    prod    = read is >>= maybe eof (return . Just)
    eof     = void m >> return Nothing
    pb s    = unRead s is


------------------------------------------------------------------------------
-- | Wraps an 'OutputStream', running the specified action when the stream
-- receives end-of-file.
--
-- /Since: 1.0.2.0/
--
atEndOfOutput :: IO b -> OutputStream a -> IO (OutputStream a)
atEndOfOutput m os = makeOutputStream f
  where
    f Nothing = write Nothing os >> void m
    f x       = write x os
