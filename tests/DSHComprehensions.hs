{-# LANGUAGE RebindableSyntax    #-}
{-# LANGUAGE ViewPatterns        #-}
{-# LANGUAGE MonadComprehensions #-}
    
-- | This module contains testcases for monad comprehensions. We store them in a
-- separate module because they rely on RebindableSyntax and hidden Prelude.
   
module DSHComprehensions where

import qualified Prelude as P
import Database.DSH
       
---------------------------------------------------------------
-- Comprehensions for quickcheck tests

cartprod :: Q ([Integer], [Integer]) -> Q [(Integer, Integer)]
cartprod (view -> (xs, ys)) =
  [ tuple2 x y
  | x <- xs
  , y <- ys
  ]

eqjoin :: Q ([Integer], [Integer]) -> Q [(Integer, Integer)]
eqjoin (view -> (xs, ys)) = 
  [ tuple2 x y
  | x <- xs
  , y <- ys
  , x == y
  ]

  
eqjoinproj :: Q ([Integer], [Integer]) -> Q [(Integer, Integer)]
eqjoinproj (view -> (xs, ys)) = 
  [ tuple2 x y
  | x <- xs
  , y <- ys
  , (2 * x) == y
  ]

eqjoinpred :: Q (Integer, [Integer], [Integer]) -> Q [(Integer, Integer)]
eqjoinpred (view -> (x', xs, ys)) = 
  [ tuple2 x y
  | x <- xs
  , y <- ys
  , x == y
  , x > x'
  ]

eqjointuples :: Q ([(Integer, Integer)], [(Integer, Integer)]) -> Q [(Integer, Integer, Integer)]
eqjointuples (view -> (xs, ys)) =
  [ tuple3 (x1 * x2) y1 y2
  | (view -> (x1, x2)) <- xs
  , (view -> (y1, y2)) <- ys
  , x1 == y2
  ]

thetajoin_eq :: Q ([(Integer, Integer)], [(Integer, Integer)]) -> Q [(Integer, Integer, Integer)]
thetajoin_eq (view -> (xs, ys)) =
  [ tuple3 (x1 * x2) y1 y2
  | (view -> (x1, x2)) <- xs
  , (view -> (y1, y2)) <- ys
  , x1 == y2
  , y1 == x2
  ]

thetajoin_neq :: Q ([(Integer, Integer)], [(Integer, Integer)]) -> Q [(Integer, Integer, Integer)]
thetajoin_neq (view -> (xs, ys)) =
  [ tuple3 (x1 * x2) y1 y2
  | (view -> (x1, x2)) <- xs
  , (view -> (y1, y2)) <- ys
  , x1 == y2
  , y1 /= x2
  ]

eqjoin3 :: Q ([Integer], [Integer], [Integer]) -> Q [(Integer, Integer, Integer)]
eqjoin3 (view -> (xs, ys, zs)) = 
  [ tuple3 x y z
  | x <- xs
  , y <- ys
  , z <- zs
  , x == y
  , y == z
  ]
  
eqjoin_nested_left :: Q ([(Integer, [Integer])], [Integer]) -> Q [((Integer, [Integer]), Integer)]
eqjoin_nested_left args =
  [ pair x y
  | x <- fst args
  , y <- snd args
  , fst x == y
  ]

eqjoin_nested_right :: Q ([Integer], [(Integer, [Integer])]) -> Q [(Integer, (Integer, [Integer]))]
eqjoin_nested_right args =
  [ pair x y
  | x <- fst args
  , y <- snd args
  , x == fst y
  ]

eqjoin_nested_both :: Q ([(Integer, [Integer])], [(Integer, [Integer])]) 
                   -> Q [((Integer, [Integer]), (Integer, [Integer]))]
eqjoin_nested_both args =
  [ pair x y
  | x <- fst args
  , y <- snd args
  , fst x == fst y
  ]

nestjoin :: Q ([Integer], [Integer]) -> Q [(Integer, [Integer])]
nestjoin (view -> (xs, ys)) =
  [ tuple2 x [ y | y <- ys, x == y]
  | x <- xs
  ]
  
--------------------------------------------------------------
-- Comprehensions for HUnit tests

eqjoin_nested1 :: Q [((Integer, [Char]), Integer)]
eqjoin_nested1 =
    [ pair x y
    | x <- (toQ ([(10, ['a']), (20, ['b']), (30, ['c', 'd']), (40, [])] :: [(Integer, [Char])]))
    , y <- (toQ [20, 30, 30, 40, 50])
    , fst x == y
    ]

semijoin :: Q [Integer]
semijoin = 
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs , x `elem` ys ]

semijoin_range :: Q [Integer]
semijoin_range = 
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6] :: Q [Integer])
    in [ x | x <- xs , x `elem` [ y | y <- ys, y < 6 ] ]

semijoin_quant :: Q [Integer]
semijoin_quant = 
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs, or [ y > 5 | y <- ys, x == y ] ]

semijoin_not_null :: Q [Integer]
semijoin_not_null =
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs, not $ null [ y | y <- ys, x == y] ]
    

antijoin :: Q [Integer]
antijoin =
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs , not $ x `elem` ys ]

antijoin_null :: Q [Integer]
antijoin_null =
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs, null [ y | y <- ys, x == y] ]

antijoin_range :: Q [Integer]
antijoin_range =
    let xs = (toQ [1, 2, 3, 4, 5, 6, 7] :: Q [Integer])
        ys = (toQ [2, 4, 6, 7] :: Q [Integer])
    in [ x | x <- xs , not $ x `elem` [ y | y <- ys, y < 5 ] ]

antijoin_class12 :: Q [Integer]
antijoin_class12 =
    let xs = toQ ([6,7,8,9,10,12] :: [Integer])
        ys = toQ ([8,9,12,13,15,16] :: [Integer])
    in [ x | x <- xs, and [ x < y | y <- ys, y > 10 ]]

antijoin_class15 :: Q [Integer]
antijoin_class15 =
    let xs = toQ ([3,4,5,6,7,8] :: [Integer])
        ys = toQ ([4,5,8,16] :: [Integer])
    in [ x | x <- xs, and [ y `mod` 4 == 0 | y <- ys, x < y ]]

antijoin_class16 :: Q [Integer]
antijoin_class16 =
    let xs = toQ ([3,4,5,6] :: [Integer])
        ys = toQ ([1,2,3,4,5,6,7,8] :: [Integer])
    in [ x | x <- xs, and [ y <= 2 * x | y <- ys, x < y ]]

----------------------------------------------------------------------
-- Comprehensions for HUnit NestJoin/NestProduct tests

nj1 :: [Integer] -> [Integer] -> Q [[Integer]]
nj1 njxs njys = 
    [ [ y | y <- toQ njys, x == y ]
    | x <- toQ njxs
    ]

nj2 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
nj2 njxs njys = 
    [ pair x [ y | y <- toQ njys, x == y ]
    | x <- toQ njxs
    ]

nj3 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
nj3 njxs njys = 
    [ pair x ([ y | y <- toQ njys, x == y ] ++ (toQ [100, 200, 300]))
    | x <- toQ njxs
    ]

nj4 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
nj4 njxs njys = 
      [ pair x ([ y | y <- toQ njys, x == y ] ++ [ z | z <- toQ njys, x == z ])
      | x <- toQ njxs
      ]

-- Code incurs DistSeg for the literal 15.
nj5 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
nj5 njxs njys = 
      [ pair x [ y | y <- toQ njys, x + y > 15 ]
      | x <- toQ njxs
      ]

nj6 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
nj6 njxs njys = 
      [ pair x [ y | y <- toQ njys, x + y > 10, y < 7 ]
      | x <- toQ njxs
      ]

nj7 :: [Integer] -> [Integer] -> Q [[Integer]]
nj7 njxs njys = 
    [ [ x + y | y <- toQ njys, x + 2 == y ] | x <- toQ njxs ]

nj8 :: [Integer] -> [Integer] -> Q [[Integer]]
nj8 njxs njys = [ [ x + y | y <- toQ njys, x == y, y < 5 ] | x <- toQ njxs, x > 3 ]

nj9 :: [Integer] -> [Integer] -> Q [[Integer]]
nj9 njxs njys = [ [ x + y | y <- toQ njys, x + 1 == y, y > 2, x < 6 ] | x <- toQ njxs ]

nj10 :: [Integer] -> [Integer] -> Q [Integer]
nj10 njxs njys = [ x + sum [ x * y | y <- toQ njys, x == y ] | x <- toQ njxs ]

nj11 :: [Integer] -> [Integer] -> Q [[Integer]]
nj11 njxs njys = [ [ x + y | y <- toQ njys, x > y, x < y * 2 ] | x <- toQ njxs ]

np1 :: [Integer] -> [Integer] -> Q [[Integer]]
np1 njxs njys = [ [ x * y * 2 | y <- toQ njys ] | x <- toQ njxs ]
	

np2 :: [Integer] -> [Integer] -> Q [(Integer, [Integer])]
np2 njxs njys = [ pair x [ y * 2 | y <- toQ njys ] | x <- toQ njxs ]

np3 :: [Integer] -> [Integer] -> Q [[Integer]]
np3 njxs njys = [ [ x + y | y <- toQ njys ] | x <- toQ njxs ]

np4 :: [Integer] -> [Integer] -> Q [[Integer]]
np4 njxs njys = [ [ y | y <- toQ njys, x > y ] | x <- toQ njxs ]

njg1 :: [Integer] -> [(Integer, Integer)] -> Q [Integer]
njg1 njgxs njgzs =
  [ x
  | x <- toQ njgxs
  , x < 8
  , sum [ snd z | z <- toQ njgzs, fst z == x ] > 100
  ]

njg2 :: [Integer] -> [Integer] -> Q [Integer]
njg2 njgxs njgys =
  [ x
  | x <- toQ njgxs
  , and [ y > 1 | y <- toQ njgys, x == y ]
  , x < 8
  ]

njg3 :: [Integer] -> [Integer] -> [(Integer, Integer)] -> Q [(Integer, Integer)]
njg3 njgxs njgys njgzs =
  [ pair x y
  | x <- toQ njgxs
  , y <- toQ njgys
  , length [ toQ () | z <- toQ njgzs, fst z == x ] > 2
  ]

njg4 :: [Integer] -> [Integer] -> [(Integer, Integer)] -> Q [Integer]
njg4 njgxs njgys njgzs =
  [ x
  | x <- toQ njgxs
  , length [ toQ () | y <- toQ njgys, x == y ] 
    > length [ toQ () | z <- toQ njgzs, fst z == x ]
  ]

njg5 :: [Integer] -> [Integer] -> Q [Integer]
njg5 njgxs njgys =
  [ x
  | x <- toQ njgxs
  , sum [ y | y <- toQ njgys, x < y, y > 5 ] < 10
  ]

--------------------------------------------------------------------------------
-- Comprehensions for QuickCheck antijoin/semijoin tests

aj_class12 :: Q ([Integer], [Integer]) -> Q [Integer]
aj_class12 (view -> (xs, ys)) = 
  [ x 
  | x <- xs
  , and [ x == y | y <- ys, y > 10 ]
  ]

aj_class15 :: Q ([Integer], [Integer]) -> Q [Integer]
aj_class15 (view -> (xs, ys)) = 
  [ x 
  | x <- xs
  , and [ y `mod` 4 == 0 | y <- ys, x < y ]
  ]

aj_class16 :: Q ([Integer], [Integer]) -> Q [Integer]
aj_class16 (view -> (xs, ys)) = 
  [ x 
  | x <- xs
  , and [ y <= 2 * x | y <- ys, x < y ]
  ]