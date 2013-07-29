{-# OPTIONS_GHC -fno-warn-unused-imports #-}

{-| @pipes@ is a lightweight and powerful library for processing effectful
    streams in constant memory.

    @pipes@ supports a wide variety of stream programming abstractions,
    including:

    * Generators, for loops, and internal \/ external iterators

    * 'ListT' done right

    * Unix pipes

    * Folds

    * Message passing and reactive programming (using the @pipes-concurrency@
      library)

    * Stream parsing (using the @pipes-parse@ library)

    * Exception-safe streams (using the @pipes-safe@ library)

    If you want a really fast Quick Start guide, read the documentation in
    "Pipes.Prelude" from top to bottom.

    This tutorial is more extensive and explains the @pipes@ API in greater
    detail and illustrates several idioms.  Also, you can find the complete code
    examples from this tutorial in the Appendix section at the bottom in case
    you want to follow along.
-}

module Pipes.Tutorial (
    -- * Producers
    -- $producers

    -- * Theory
    -- $theory

    -- * Consumers
    -- $consumers

    -- * Pipes
    -- $pipes

    -- * Appendix
    -- $appendix
    ) where

import Control.Category
import Control.Monad.Trans.Error
import Control.Monad.Trans.Writer.Strict
import Pipes
import Pipes.Lift
import qualified Pipes.Prelude as P
import Prelude hiding ((.), id)

{- $producers
    The library represents effectful streams of input using 'Producer's.  A
    'Producer' is a monad transformer that extends the base monad with the
    ability to incrementally 'yield' output.  The following @stdin@ 'Producer'
    shows how to incrementally read and 'yield' lines from standard input,
    terminating when we reach the end of the input:

> -- echo.hs
>
> import Control.Monad (unless)
> import Pipes
> import qualified System.IO as IO
>
> --       +--------+-- A 'Producer' of 'String's
> --       |        |
> --       |        |      +-- The base monad is 'IO'
> --       |        |      |
> --       |        |      |  +-- Returns '()' when finished
> --       |        |      |  |
> --       v        v      v  v
> stdin :: Producer String IO ()
> stdin = do
>     eof <- lift $ IO.hIsEOF IO.stdin  -- 'lift' actions from the base monad
>     unless eof $ do
>         str <- lift getLine           -- Read a line of input
>         yield str                     -- 'yield' the line of input
>         stdin                         -- Loop

    'yield' emits a value, suspending the current 'Producer' until the value is
    consumed:

> yield :: (Monad m) => a -> Producer a m ()

    The simplest way to consume a 'Producer' is a 'for' loop, which has the
    following type:

> for :: (Monad m) => Producer a m r -> (a -> Producer b m r) -> Producer b m r

    Notice how this type greatly resembles the type of @(flip concatMap)@ (or
    ('>>=') for the list monad):

> flip concatMap :: [a] -> (a -> [b]) -> [b]

    Here's an example 'for' @loop@:

> -- echo.hs
>
> --               +-- 'loop' does not emit any values, so 'a' is polymorphic
> --               |
> --               v
> loop :: Producer a IO ()
> loop = for stdin $ \str -> do  -- Read this like: "for str in stdin"
>     lift $ putStrLn str        -- The body of the 'for' loop
>
> -- even better: loop = for stdin (lift . putStrLn)

    Notice how 'loop' does not re-emit any values in the body of the 'for' loop.
    @pipes@ defines a type synonym for this special case:

> data X  -- The uninhabited type
>
> type Effect m r = Producer X m r

    Since 'X' is uninhabited, a 'Producer' only type-checks as an 'Effect' if
    the 'Producer' never outputs any values.  This means we can change the type
    signature of @loop@ to:

> loop :: (Monad m) => Effect IO ()

    'Effect's are special because we can 'run' any 'Effect' and convert it back
    to the base monad:

> run :: (Monad m) => Effect m r -> m r

    'run' only accepts 'Effect's and refuses to silently discard unhandled
    output.  Our @loop@ has no unhandled output, so the following use of 'run'
    type-checks:

> -- echo.hs
>
> main :: IO ()
> main = run loop

    Our final program loops over standard input and echoes every line to
    standard output:

> $ ghc -O2 echo.hs
> $ ./echo
> Test<Enter>
> Test
> ABC<Enter>
> ABC
> ^D
> $

    You can also loop over lists, too.  To do so, convert the list to a
    'Producer' using 'each':

> each :: (Monad m) => [a] -> Producer a m ()
> each as = mapM_ yield as

    Use this to iterate over lists using a \"foreach\" loop:

>>> run $ for (each [1..4]) (lift . print)
1
2
3
4

-}

{- $theory
    You might wonder why the body of a 'for' loop can be a 'Producer'.  Let's
    test out this feature by defining a new loop body that re-'yield's every
    value twice:

> -- nested.hs
>
> import Pipes
> import qualified Pipes.Prelude as P  -- Pipes.Prelude already has 'stdin'
>
> body :: (Monad m) => a -> Producer a m ()
> body x = do
>     yield x
>     yield x
>
> loop :: Producer String IO ()
> loop = for P.stdin body
>
> -- This is the same as:
> --
> -- loop = for P.stdin $ \str -> do
> --     yield str
> --     yield str

    This time our @loop@ outputs 'String's, specifically two copies of every
    line read from standard input.

    Since @loop@ is itself a 'Producer', we can loop over our @loop@, dawg:

> -- nested.hs
>
> main = run $ for loop (lift . putStrLn)

    This creates a program which echoes every line from standard input to
    standard output twice:

> $ ./nested
> Test<Enter>
> Test
> Test
> ABC<Enter>
> ABC
> ABC
> ^D
> $

    But is this feature really necessary?  Couldn't we have instead written this
    using a nested for loop?

> main = run $
>     for P.stdin $ \str1 ->
>         for (body str1) $ \str2 ->
>             lift $ putStrLn str

    Yes, we could have!  In fact, this is a special case of the following
    equality, which always holds no matter what:

> -- m :: (Monad m) =>      Producer a m ()  -- i.e. 'P.stdin'
> -- f :: (Monad m) => a -> Producer b m ()  -- i.e. 'body'
> -- g :: (Monad m) => b -> Producer c m ()  -- i.e. '(lift . putStrLn)'
>
> for (for m f) g = for m (\x -> for (f x) g)

    We can understand the rationale behind this equality if we define the
    following operator that is the point-free counterpart to 'for':

> (/>/) :: (Monad m)
>       => (a -> Producer b m r)
>       -> (b -> Producer c m r)
>       -> (a -> Producer c m r)
> (f />/ g) x = for (f x) g

    Using this operator we can transform our original equality into the
    following more symmetric form:

> f :: (Monad m) => a -> Producer b m r
> g :: (Monad m) => b -> Producer c m r
> h :: (Monad m) => c -> Producer d m r
>
> -- Associativity
> (f />/ g) />/ h = f />/ (g />/ h)

    This looks just like an associativity law.  In fact, ('/>/') has another
    nice property, which is that 'yield' is its left and right identity:

> -- Left Identity
> yield />/ f = f
>
> -- Right Identity
> f />/ yield = f

    In other words, 'yield' and ('/>/') form a 'Control.Category.Category' where
    ('/>/') plays the role of the composition operator and 'yield' is the
    identity.

    Notice that if we translate the left identity law to use 'for' instead of
    ('/>/') we get:

> for (yield x) f = f x

    This just says that if you iterate over a single-element 'Producer' with no
    side effects, then you can instead cut out the middle man and directly apply
    the body of the loop to that single element.

    If we translate the right identity law to use 'for' instead of ('/>/') we
    get:

> for m yield = m

    This just says that if the only thing you do is re-'yield' every element of
    a stream, you get back your original stream.

    These three \"for loop\" laws summarize our intuition for how 'for' loops
    should behave:

> for (for m f) g = for m (\x -> for (f x) g)
>
> for (yield x) f = f x
>
> for m yield = m

    ... and they miraculously fall out of the 'Control.Category.Category' laws
    for ('/>/') and 'yield'.

    In fact, we get more out of this than just a bunch of equations.  We also
    got a useful operator, too: ('/>/').  We can use this operator to condense
    our original code into the following more succinct form:

> main = run $ for P.stdin (body />/ lift . putStrLn)

    This means that we can also choose to program in a more functional style and
    think of stream processing in terms of composing transformations using
    ('/>/') instead of nesting a bunch of 'for' loops.

    The above example is a microcosm of the design philosophy behind the @pipes@
    library:

    * Define primitives in terms of categories

    * Specify expected behavior in terms of category laws

    * Think compositionally instead of sequentially
-}

{- $consumers
    Sometimes you don't want use a 'for' loop because you don't want to consume
    every element of a 'Producer' or because you don't want to process every
    value of a 'Producer' the exact same way.

    The most general solution is to externally iterate over the 'Producer' using
    the 'next' command:

> next :: (Monad m) => Producer a m r -> m (Either r (a, Producer a m r))

    Think of 'next' as pattern matching on the head of the 'Producer'.  This
    'Either' returns a 'Left' if the 'Producer' is done or it returns a 'Right'
    containing the next value, @a@, along with the remainder of the 'Producer'.

    However, sometimes we can get away with something a little more elegant,
    like a 'Consumer', which represents an effectful fold.  A 'Consumer' is a
    monad transformer that extends the base monad with the ability to
    incrementally 'await' input.  The following @printN@ 'Consumer' shows how to
    'print' out only the first @n@ elements received:

> -- printn.hs
>
> import Control.Monad (replicateM_)
> import Pipes
> import qualified Pipes.Prelude as P
>
> --               +--------+-- A 'Consumer' of 'String's
> --               |        |
> --               v        v
> printN :: Int -> Consumer String IO ()
> printN n = replicateM_ n $ do  -- Repeat the following block 'n' times
>     str <- await ()            -- 'await' a new 'String'
>     lift $ putStrLn str        -- Print out the 'String'

    'await' is the dual of 'yield': we suspend our 'Pipe' until we are supplied
    with a new value:

> await :: (Monad m) => () -> Consumer a m a

    Use ('~>') to connect a 'Producer' to a 'Consumer':

> (~>) :: (Monad m)
>      => Producer a m r
>      -> Consumer a m r
>      -> Effect     m r

    This returns an 'Effect' which we can 'run':

> -- printn.hs
>
> main = run $ P.stdin ~> printN 3

    This will prompt the user for input three times, echoing each input:

> $ ./printn
> Test<Enter>
> Test
> ABC<Enter>
> ABC
> 42<Enter>
> 42
> $

    ('~>') pairs every 'await' in the 'Consumer' with a 'yield' in the
    'Producer'.  Since our 'Consumer' only calls 'await' three times, our
    'Producer' only 'yield's three times and therefore only prompts the user
    for input three times.  Once the 'Consumer' terminates the whole 'Effect'
    terminates.

    The opposite is true, too: if the 'Producer' terminates, then the whole
    'Effect' terminates.

> $ ./printn
> Test<Enter>
> Test
> ^D
> $

    This is why ('~>') requires that both the 'Producer' and 'Consumer' share
    the same of return value: whichever one terminates first provides the return
    value for the entire 'Effect'.

    Let's test this by modifying our 'Producer' to return 'False' and our
    'Consumer' to return 'True':

> -- printn.hs
>
> import Control.Applicative ((<$))  -- (<$) modifies return values
>
> main = do
>     finished <- run $ (False <$ P.stdin) ~> (True <$ printN 3)
>     putStrLn $ if finished then "Success!" else "You had one job..."

    This lets us diagnose whether the 'Producer' or 'Consumer' terminated first:

> $ ./printn
> Test<Enter>
> Test
> ABC<Enter>
> ABC
> 42<Enter>
> 42
> Success!
> $ ./printn
> ^D
> You had one job...
> $
-}

{- $pipes
    You might wonder why ('~>') returns an 'Effect' that we have to 'run'
    instead of directly returning an action in the base monad.  This is because
    you can connect things other than 'Producer's and 'Consumer's, like 'Pipe's.
    A 'Pipe' is a monad transformer that is a mix between a 'Producer' and
    'Consumer', because a 'Pipe' can both 'await' and 'yield'.  The following
    @take@ 'Pipe' only allows a fixed number of values to pass through:
-}

{- $conclusion
    This tutorial covers the core concepts of connecting, building, and reading
    @pipes@ code.  However, this library is only the core component in an
    ecosystem of streaming components.  More powerful libraries that build upon
    @pipes@ include:

    * @pipes-safe@: Resource management and exception safety for @pipes@

    * @pipes-concurrency@: Concurrent reactive programming and message passing

    * @pipes-parse@: Central idioms for stream parsing

    * @pipes-arrow@: Push-based directed acyclic graphs for @pipes@

    These libraries provide functionality specialized to common streaming
    domains.  Additionally, there are several derived libraries on Hackage that
    provide even higher-level functionality, which you can find by searching
    under the \"Pipes\" category or by looking for packages with a @pipes-@
    prefix in their name.  Current examples include:

    * @pipes-network@/@pipes-network-tls@: Networking

    * @pipes-zlib@: Compression and decompression

    * @pipes-binary@: Binary serialization

    * @pipes-attoparsec@: High-performance parsing

    Even these derived packages still do not explore the full potential of
    @pipes@ functionality.  Advanced @pipes@ users can explore this library in
    greater detail by studying the documentation in the "Pipes" module to learn
    about the symmetry behind the underlying 'Proxy' type and operators.

    To learn more about @pipes@, ask questions, or follow @pipes@ development,
    you can subscribe to the @haskell-pipes@ mailing list at:

    <https://groups.google.com/forum/#!forum/haskell-pipes>

    ... or you can mail the list directly at
    <mailto:haskell-pipes@googlegroups.com>.
-}

{- $appendix

> -- echo.hs
>
> import Control.Monad (unless)
> import Pipes
> import qualified System.IO as IO
>
> stdin :: Producer String IO ()
> stdin = do
>     eof <- lift $ IO.hIsEOF IO.stdin
>     unless eof $ do
>         str <- lift getLine
>         yield str
>         stdin
>
> loop :: Effect IO ()
> loop = for stdin $ \str -> do
>     lift $ putStrLn str
>
> main :: IO ()
> main = run loop

> -- nested.hs
>
> import Pipes
> import qualified Pipes.Prelude as P
>
> body :: (Monad m) => a -> Producer a m ()
> body x = do
>     yield x
>     yield x
>
> loop :: Producer String IO ()
> loop = for P.stdin body
>
> main  = run $ for loop (lift . putStrLn)

-}