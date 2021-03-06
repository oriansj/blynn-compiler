-- Copyright © 2019 Ben Lynn
-- This file is part of blynn-compiler.

-- blynn-compiler is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, only under version 3 of
-- the License.

-- blynn-compiler is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
-- General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with blynn-compiler.  If not, see
-- <https://www.gnu.org/licenses/>.
-- Arbitrary precision arithmetic (`Integer`).

ffi "putchar_cast" putChar :: Char -> IO ()
ffi "getargcount" getArgCount :: IO Int
ffi "getargchar" getArgChar :: Int -> Int -> IO Char
ffi "getchar_fp" getChar :: IO Int
ffi "reset_buffer" resetBuffer :: IO ()
ffi "put_buffer" putBuffer :: Int -> IO ()
ffi "stdin_load_buffer" stdinLoadBuffer :: IO ()

infixr 9 .
infixl 7 * , `div` , `mod`
infixl 6 + , -
infixr 5 ++
infixl 4 <*> , <$> , <* , *>
infix 4 == , /= , <=
infixl 3 && , <|>
infixl 2 ||
infixl 1 >> , >>=
infixr 0 $

fromIntegral = fromInteger . toInteger

-- Integer literals in `fromInt`, `fromInteger` or any of their dependencies
-- cause infinite loops, because our compilers apply `fromInt` or `fromInteger`
-- to integer literal. We get `0 :: Int` in a roundabout way:
zeroInt = ord '\0'

fromInt x
  | x == zeroInt = fromInteger $ Integer True []
  | True = fromInteger . Integer True . (:[]) $ wordFromInt x

class Ring a where
  (+) :: a -> a -> a
  (-) :: a -> a -> a
  (*) :: a -> a -> a
  fromInteger :: Integer -> a
class Integral a where
  div :: a -> a -> a
  mod :: a -> a -> a
  quot :: a -> a -> a
  rem :: a -> a -> a
  toInteger :: a -> Integer
  -- divMod, quotRem

instance Ring Int where
  (+) = intAdd
  (-) = intSub
  (*) = intMul
  -- TODO: Negative case.
  fromInteger (Integer xsgn xs) = intFromWord $ fst $ mpView xs
instance Integral Int where
  div = intDiv
  mod = intMod
  quot = intQuot
  rem = intRem
  toInteger x
    | 0 <= x = Integer True $ if x == 0 then [] else [wordFromInt x]
    | True = Integer False [wordFromInt $ 0 - x]

instance Ring Word where
  (+) = wordAdd
  (-) = wordSub
  (*) = wordMul
  -- TODO: Negative case.
  fromInteger (Integer xsgn xs) = fst $ mpView xs
instance Integral Word where
  div = wordDiv
  mod = wordMod
  quot = wordQuot
  rem = wordRem
  toInteger 0 = Integer True []
  toInteger x = Integer True [x]
instance Eq Word where (==) = wordEq
instance Ord Word where (<=) = wordLE

data Word64 = Word64 Word Word deriving Eq
instance Ring Word64 where
  Word64 a b + Word64 c d = uncurry Word64 $ word64Add a b c d
  Word64 a b - Word64 c d = uncurry Word64 $ word64Sub a b c d
  Word64 a b * Word64 c d = uncurry Word64 $ word64Mul a b c d
  -- TODO: Negative case.
  fromInteger (Integer xsgn xs) = Word64 x y where
    (x, xt) = mpView xs
    (y, _) = mpView xt

instance Ord Word64 where
  Word64 a b <= Word64 c d
    | b == d = a <= c
    | True = b <= d

-- Multiprecision arithmetic.
data Integer = Integer Bool [Word] deriving Eq
instance Ring Integer where
  Integer xsgn xs + Integer ysgn ys
    | xsgn == ysgn = Integer xsgn $ mpAdd xs ys
    | True = case mpCompare xs ys of
      LT -> mpCanon ysgn $ mpSub ys xs
      _ -> mpCanon xsgn $ mpSub xs ys
  Integer xsgn xs - Integer ysgn ys
    | xsgn /= ysgn = Integer xsgn $ mpAdd xs ys
    | True = case mpCompare xs ys of
      LT -> mpCanon (not ysgn) $ mpSub ys xs
      _ -> mpCanon xsgn $ mpSub xs ys
  Integer xsgn xs * Integer ysgn ys = Integer (xsgn == ysgn) $ mpMul xs ys
  fromInteger = id

instance Integral Integer where
  -- TODO: Trucate `div` towards zero.
  div (Integer xsgn xs) (Integer ysgn ys) = mpCanon0 (xsgn == ysgn) $ fst $ mpDivMod xs ys
  mod (Integer xsgn xs) (Integer ysgn ys) = mpCanon0 ysgn $ snd $ mpDivMod xs ys
  quot (Integer xsgn xs) (Integer ysgn ys) = mpCanon0 (xsgn == ysgn) $ fst $ mpDivMod xs ys
  rem (Integer xsgn xs) (Integer ysgn ys) = mpCanon0 ysgn $ snd $ mpDivMod xs ys
  toInteger = id

instance Ord Integer where
  compare (Integer xsgn xs) (Integer ysgn ys)
    | xsgn = if ysgn then mpCompare xs ys else GT
    | True = if ysgn then LT else mpCompare ys xs

mpView [] = (wordFromInt zeroInt, [])
mpView (x:xt) = (x, xt)

mpCanon sgn xs = mpCanon0 sgn $ reverse $ dropWhile (0 ==) $ reverse xs
mpCanon0 sgn xs = case xs of
  [] -> Integer True []
  _ -> Integer sgn xs

mpCompare [] [] = EQ
mpCompare [] _  = LT
mpCompare _  [] = GT
mpCompare (x:xt) (y:yt) = case mpCompare xt yt of
  EQ -> compare x y
  o -> o

mpAdc [] [] c = ([], c)
mpAdc xs ys c = first (lo:) $ mpAdc xt yt hi where
  (x, xt) = mpView xs
  (y, yt) = mpView ys
  (lo,hi) = uncurry (word64Add c 0) $ word64Add x 0 y 0

mpAdd xs ys | c == 0 = zs
            | True = zs ++ [c]
  where (zs, c) = mpAdc xs ys 0

mpSub xs ys = fst $ mpSbb xs ys 0

mpSbb xs ys b = go xs ys b where
  go [] [] b = ([], b)
  go xs ys b = first (lo:) $ go xt yt $ 1 - hi where
    (x, xt) = mpView xs
    (y, yt) = mpView ys
    (lo,hi) = uncurry word64Sub (word64Sub x 1 y 0) b 0

mpMulWord _ []     c = if c == 0 then [] else [c]
mpMulWord x (y:yt) c = lo:mpMulWord x yt hi where
  (lo, hi) = uncurry (word64Add c 0) $ word64Mul x 0 y 0

mpMul [] _ = []
mpMul (x:xt) ys = case mpMulWord x ys 0 of
  [] -> []
  z:zs -> z:mpAdd zs (mpMul xt ys)

mpDivModWord xs y = first (reverse . dropWhile (0 ==)) $ go 0 $ reverse xs where
  go r [] = ([], r)
  go n (x:xt) = first (q:) $ go r xt where
    q = fst $ word64Div x n y 0
    r = fst $ word64Mod x n y 0

mpDivMod xs ys = first (reverse . dropWhile (== 0)) $ go us where
  s = mpDivScale $ last ys
  us = mpMulWord s (xs ++ [0]) 0
  vs = mpMulWord s ys 0
  (v1:vt) = reverse vs
  vlen = length vs
  go us | ulen <= vlen = ([], fst $ mpDivModWord us s)
        | True = first (q:) $ go $ lsbs ++ init ds
    where
    ulen = length us
    (u0:u1:ut) = reverse us
    (lsbs, msbs) = splitAt (ulen - vlen - 1) us
    (ql, qh) = word64Div u1 u0 v1 0
    q0  = if 1 <= qh then (0-1) else ql
    (q, ds) = foldr const undefined [(q, ds) | q <- iterate (- 1) q0, let (ds, bor) = mpSbb msbs (mpMulWord q vs 0) 0, bor == 0]

mpDivScale n = fst $ word64Div 0 1 (n + 1) 0

class Functor f where fmap :: (a -> b) -> f a -> f b
class Applicative f where
  pure :: a -> f a
  (<*>) :: f (a -> b) -> f a -> f b
class Monad m where
  return :: a -> m a
  (>>=) :: m a -> (a -> m b) -> m b
(<$>) = fmap
liftA2 f x y = f <$> x <*> y
(>>) f g = f >>= \_ -> g
class Eq a where (==) :: a -> a -> Bool
instance Eq Int where (==) = intEq
instance Eq Char where (==) = charEq
($) f x = f x
id x = x
const x y = x
flip f x y = f y x
(&) x f = f x
data Ordering = LT | GT | EQ
class Ord a where
  (<=) :: a -> a -> Bool
  x <= y = case compare x y of
    LT -> True
    EQ -> True
    GT -> False
  compare :: a -> a -> Ordering
  compare x y = if x <= y then if y <= x then EQ else LT else GT

instance Ord Int where (<=) = intLE
instance Ord Char where (<=) = charLE
instance Ord a => Ord [a] where
  xs <= ys = case xs of
    [] -> True
    x:xt -> case ys of
      [] -> False
      y:yt -> case compare x y of
        LT -> True
        GT -> False
        EQ -> xt <= yt
data Maybe a = Nothing | Just a
data Either a b = Left a | Right b
fpair (x, y) f = f x y
fst (x, y) = x
snd (x, y) = y
uncurry f (x, y) = f x y
first f (x, y) = (f x, y)
second f (x, y) = (x, f y)
not a = if a then False else True
x /= y = not $ x == y
(.) f g x = f (g x)
(||) f g = if f then True else g
(&&) f g = if f then g else False
flst xs n c = case xs of [] -> n; h:t -> c h t
instance Eq a => Eq [a] where
  xs == ys = case xs of
    [] -> case ys of
      [] -> True
      _ -> False
    x:xt -> case ys of
      [] -> False
      y:yt -> x == y && xt == yt
take 0 xs = []
take _ [] = []
take n (h:t) = h : take (n - 1) t
drop n xs     | n <= 0 =  xs
drop _ []              =  []
drop n (_:xs)          =  drop (n-1) xs
splitAt n xs = (take n xs, drop n xs)
maybe n j m = case m of Nothing -> n; Just x -> j x
instance Functor Maybe where fmap f = maybe Nothing (Just . f)
instance Applicative Maybe where pure = Just ; mf <*> mx = maybe Nothing (\f -> maybe Nothing (Just . f) mx) mf
instance Monad Maybe where return = Just ; mf >>= mg = maybe Nothing mg mf
instance Alternative Maybe where empty = Nothing ; x <|> y = maybe y Just x
foldr c n l = flst l n (\h t -> c h(foldr c n t))
length = foldr (\_ n -> n + 1) 0
mapM f = foldr (\a rest -> liftA2 (:) (f a) rest) (pure [])
mapM_ f = foldr ((>>) . f) (pure ())
foldM f z0 xs = foldr (\x k z -> f z x >>= k) pure xs z0
instance Applicative IO where pure = ioPure ; (<*>) f x = ioBind f \g -> ioBind x \y -> ioPure (g y)
instance Monad IO where return = ioPure ; (>>=) = ioBind
instance Functor IO where fmap f x = ioPure f <*> x
putStr = mapM_ putChar
getContents = getChar >>= \n -> if 0 <= n then (chr n:) <$> getContents else pure []
interact f = getContents >>= putStr . f
error s = unsafePerformIO $ putStr s >> putChar '\n' >> exitSuccess
undefined = error "undefined"
foldr1 c l@(h:t) = maybe undefined id $ foldr (\x m -> Just $ maybe x (c x) m) Nothing l
foldl f a bs = foldr (\b g x -> g (f x b)) (\x -> x) bs a
foldl1 f (h:t) = foldl f h t
reverse = foldl (flip (:)) []
dropWhile _ [] = []
dropWhile p xs@(x:xt)
  | p x       = dropWhile p xt
  | True = xs
elem k xs = foldr (\x t -> x == k || t) False xs
find f xs = foldr (\x t -> if f x then Just x else t) Nothing xs
(++) = flip (foldr (:))
concat = foldr (++) []
map = flip (foldr . ((:) .)) []
instance Functor [] where fmap = map
instance Applicative [] where pure = (:[]); f <*> x = concatMap (<$> x) f
instance Monad [] where return = (:[]); (>>=) = flip concatMap
concatMap = (concat .) . map
lookup s = foldr (\(k, v) t -> if s == k then Just v else t) Nothing
filter f = foldr (\x xs -> if f x then x:xs else xs) []
union xs ys = foldr (\y acc -> (if elem y acc then id else (y:)) acc) xs ys
intersect xs ys = filter (\x -> maybe False (\_ -> True) $ find (x ==) ys) xs
last xs = flst xs undefined last' where last' x xt = flst xt x \y yt -> last' y yt
init (x:xt) = flst xt [] \_ _ -> x : init xt
intercalate sep xs = flst xs [] \x xt -> x ++ concatMap (sep ++) xt
intersperse sep xs = flst xs [] \x xt -> x : foldr ($) [] (((sep:) .) . (:) <$> xt)
all f = foldr (&&) True . map f
any f = foldr (||) False . map f
zipWith f xs ys = flst xs [] $ \x xt -> flst ys [] $ \y yt -> f x y : zipWith f xt yt
zip = zipWith (,)
data State s a = State (s -> (a, s))
runState (State f) = f
instance Functor (State s) where fmap f = \(State h) -> State (first f . h)
instance Applicative (State s) where
  pure a = State (a,)
  (State f) <*> (State x) = State \s -> fpair (f s) \g s' -> first g $ x s'
instance Monad (State s) where
  return a = State (a,)
  (State h) >>= f = State $ uncurry (runState . f) . h
evalState m s = fst $ runState m s
get = State \s -> (s, s)
put n = State \s -> ((), n)
either l r e = case e of Left x -> l x; Right x -> r x
instance Functor (Either a) where fmap f e = either Left (Right . f) e
instance Applicative (Either a) where
  pure = Right
  ef <*> ex = case ef of
    Left s -> Left s
    Right f -> either Left (Right . f) ex
instance Monad (Either a) where
  return = Right
  ex >>= f = either Left f ex
iterate f x = x : iterate f (f x)
takeWhile _ [] = []
takeWhile p xs@(x:xt)
  | p x  = x : takeWhile p xt
  | True = []
class Alternative f where
  empty :: f a
  (<|>) :: f a -> f a -> f a
asum = foldr (<|>) empty
(*>) = liftA2 \x y -> y
(<*) = liftA2 \x y -> x
many p = liftA2 (:) p (many p) <|> pure []
some p = liftA2 (:) p (many p)
sepBy1 p sep = liftA2 (:) p (many (sep *> p))
sepBy p sep = sepBy1 p sep <|> pure []
between x y p = x *> (p <* y)
class Enum a where
  succ           :: a -> a
  pred           :: a -> a
  toEnum         :: Int -> a
  fromEnum       :: a -> Int
  enumFrom       :: a -> [a]
  enumFrom = iterate succ
  enumFromTo     :: a -> a -> [a]
instance Enum Int where
  succ = (+1)
  pred = (+(0-1))
  toEnum = id
  fromEnum = id
  enumFromTo lo hi = takeWhile (<= hi) $ enumFrom lo
instance Enum Char where
  succ = chr . (+1) . ord
  pred = chr . (+(0-1)) . ord
  toEnum = chr
  fromEnum = ord
  enumFromTo lo hi = takeWhile (<= hi) $ enumFrom lo

-- Map.
data Map k a = Tip | Bin Int k a (Map k a) (Map k a)
size m = case m of Tip -> 0 ; Bin sz _ _ _ _ -> sz
node k x l r = Bin (1 + size l + size r) k x l r
singleton k x = Bin 1 k x Tip Tip
singleL k x l (Bin _ rk rkx rl rr) = node rk rkx (node k x l rl) rr
doubleL k x l (Bin _ rk rkx (Bin _ rlk rlkx rll rlr) rr) =
  node rlk rlkx (node k x l rll) (node rk rkx rlr rr)
singleR k x (Bin _ lk lkx ll lr) r = node lk lkx ll (node k x lr r)
doubleR k x (Bin _ lk lkx ll (Bin _ lrk lrkx lrl lrr)) r =
  node lrk lrkx (node lk lkx ll lrl) (node k x lrr r)
balance k x l r = f k x l r where
  f | size l + size r <= 1 = node
    | 5 * size l + 3 <= 2 * size r = case r of
      Tip -> node
      Bin sz _ _ rl rr -> if 2 * size rl + 1 <= 3 * size rr
        then singleL
        else doubleL
    | 5 * size r + 3 <= 2 * size l = case l of
      Tip -> node
      Bin sz _ _ ll lr -> if 2 * size lr + 1 <= 3 * size ll
        then singleR
        else doubleR
    | True = node
insert kx x t = case t of
  Tip -> singleton kx x
  Bin sz ky y l r -> case compare kx ky of
    LT -> balance ky y (insert kx x l) r
    GT -> balance ky y l (insert kx x r)
    EQ -> Bin sz kx x l r
insertWith f kx x t = case t of
  Tip -> singleton kx x
  Bin sy ky y l r -> case compare kx ky of
    LT -> balance ky y (insertWith f kx x l) r
    GT -> balance ky y l (insertWith f kx x r)
    EQ -> Bin sy kx (f x y) l r
mlookup kx t = case t of
  Tip -> Nothing
  Bin _ ky y l r -> case compare kx ky of
    LT -> mlookup kx l
    GT -> mlookup kx r
    EQ -> Just y
fromList = foldl (\t (k, x) -> insert k x t) Tip
member k t = maybe False (const True) $ mlookup k t
t ! k = maybe undefined id $ mlookup k t

foldrWithKey f = go where
  go z t = case t of
    Tip -> z
    Bin _ kx x l r -> go (f kx x (go z r)) l

toAscList = foldrWithKey (\k x xs -> (k,x):xs) []

-- Syntax tree.
data Type = TC String | TV String | TAp Type Type deriving Eq
arr a b = TAp (TAp (TC "->") a) b
data Extra = Basic Int | Const Integer | ChrCon Char | StrCon String
data Pat = PatLit Extra | PatVar String (Maybe Pat) | PatCon String [Pat]
data Ast = E Extra | V String | A Ast Ast | L String Ast | Pa [([Pat], Ast)] | Ca Ast [(Pat, Ast)] | Proof Pred
data Constr = Constr String [(String, Type)]
data Pred = Pred String Type deriving Eq
data Qual = Qual [Pred] Type
noQual = Qual []

typeVars = \case
  TC _ -> []
  TV v -> [v]
  TAp x y -> typeVars x `union` typeVars y

data Instance = Instance
  -- Type, e.g. Int for Eq Int.
  Type
  -- Dictionary name, e.g. "{Eq Int}"
  String
  -- Context.
  [Pred]
  -- Method definitions
  (Map String Ast)

data Tycl = Tycl
  -- | Method names and their default implementations.
  -- Their types are kept in a global table.
  [(String, Maybe Ast)]
  -- | Instances.
  [Instance]

data Neat = Neat
  (Map String Tycl)
  -- | Top-level definitions. Top-level type annotations.
  ([(String, Ast)], [(String, Qual)])
  -- | Typed ASTs, ready for compilation, including ADTs and methods,
  -- e.g. (==), (Eq a => a -> a -> Bool, select-==)
  [(String, (Qual, Ast))]
  -- | Data constructor table.
  (Map String [Constr])  -- AdtTab
  -- | FFI declarations.
  [(String, Type)]
  -- | Exports.
  [(String, String)]

patVars = \case
  PatLit _ -> []
  PatVar s m -> s : maybe [] patVars m
  PatCon _ args -> concat $ patVars <$> args

fv bound = \case
  V s | not (elem s bound) -> [s]
  A x y -> fv bound x `union` fv bound y
  L s t -> fv (s:bound) t
  _ -> []

fvPro bound expr = case expr of
  V s | not (elem s bound) -> [s]
  A x y -> fvPro bound x `union` fvPro bound y
  L s t -> fvPro (s:bound) t
  Pa vsts -> foldr union [] $ map (\(vs, t) -> fvPro (concatMap patVars vs ++ bound) t) vsts
  Ca x as -> fvPro bound x `union` fvPro bound (Pa $ first (:[]) <$> as)
  _ -> []

overFree s f t = case t of
  E _ -> t
  V s' -> if s == s' then f t else t
  A x y -> A (overFree s f x) (overFree s f y)
  L s' t' -> if s == s' then t else L s' $ overFree s f t'

overFreePro s f t = case t of
  E _ -> t
  V s' -> if s == s' then f t else t
  A x y -> A (overFreePro s f x) (overFreePro s f y)
  L s' t' -> if s == s' then t else L s' $ overFreePro s f t'
  Pa vsts -> Pa $ map (\(vs, t) -> (vs, if any (elem s . patVars) vs then t else overFreePro s f t)) vsts
  Ca x as -> Ca (overFreePro s f x) $ (\(p, t) -> (p, if elem s $ patVars p then t else overFreePro s f t)) <$> as

beta s t x = overFree s (const t) x

showParen b f = if b then ('(':) . f . (')':) else f
showInt' n = if 0 == n then id else (showInt' $ n`div`10) . ((:) (chr $ 48+n`mod`10))
showInt n = if 0 == n then ('0':) else showInt' n
par = showParen True
showType t = case t of
  TC s -> (s++)
  TV s -> (s++)
  TAp (TAp (TC "->") a) b -> par $ showType a . (" -> "++) . showType b
  TAp a b -> par $ showType a . (' ':) . showType b
showPred (Pred s t) = (s++) . (' ':) . showType t . (" => "++)

-- Lexer.
data LexState = LexState String (Int, Int)
data Lexer a = Lexer (LexState -> Either String (a, LexState))
instance Functor Lexer where fmap f (Lexer x) = Lexer $ fmap (first f) . x
instance Applicative Lexer where
  pure x = Lexer \inp -> Right (x, inp)
  f <*> x = Lexer \inp -> case lex f inp of
    Left e -> Left e
    Right (fun, t) -> case lex x t of
      Left e -> Left e
      Right (arg, u) -> Right (fun arg, u)
instance Monad Lexer where
  return = pure
  x >>= f = Lexer \inp -> case lex x inp of
    Left e -> Left e
    Right (a, t) -> lex (f a) t
instance Alternative Lexer where
  empty = Lexer \_ -> Left ""
  (<|>) x y = Lexer \inp -> either (const $ lex y inp) Right $ lex x inp

lex (Lexer f) inp = f inp
advanceRC x (r, c)
  | n `elem` [10, 11, 12, 13] = (r + 1, 1)
  | n == 9 = (r, (c + 8)`mod`8)
  | True = (r, c + 1)
  where n = ord x
pos = Lexer \inp@(LexState _ rc) -> Right (rc, inp)
sat f = Lexer \(LexState inp rc) -> flst inp (Left "EOF") \h t ->
  if f h then Right (h, LexState t $ advanceRC h rc) else Left "unsat"
char c = sat (c ==)

data Token = Reserved String
  | VarId String | VarSym String | ConId String | ConSym String
  | Lit Extra

hexValue d
  | d <= '9' = ord d - ord '0'
  | d <= 'F' = 10 + ord d - ord 'A'
  | d <= 'f' = 10 + ord d - ord 'a'
isSpace c = elem (ord c) [32, 9, 10, 11, 12, 13, 160]
isNewline c = ord c `elem` [10, 11, 12, 13]
isSymbol = (`elem` "!#$%&*+./<=>?@\\^|-~:")
dashes = char '-' *> some (char '-')
comment = dashes *> (sat isNewline <|> sat (not . isSymbol) *> many (sat $ not . isNewline) *> sat isNewline)
small = sat \x -> ((x <= 'z') && ('a' <= x)) || (x == '_')
large = sat \x -> (x <= 'Z') && ('A' <= x)
hexit = sat \x -> (x <= '9') && ('0' <= x)
  || (x <= 'F') && ('A' <= x)
  || (x <= 'f') && ('a' <= x)
digit = sat \x -> (x <= '9') && ('0' <= x)
decimal = foldl (\n d -> 10*n + toInteger (ord d - ord '0')) 0 <$> some digit
hexadecimal = foldl (\n d -> 16*n + toInteger (hexValue d)) 0 <$> some hexit

escape = char '\\' *> (sat (`elem` "'\"\\") <|> char 'n' *> pure '\n' <|> char '0' *> pure (chr 0))
tokOne delim = escape <|> sat (delim /=)

tokChar = between (char '\'') (char '\'') (tokOne '\'')
tokStr = between (char '"') (char '"') $ many (tokOne '"')
integer = char '0' *> (char 'x' <|> char 'X') *> hexadecimal <|> decimal
literal = Lit . Const <$> integer <|> Lit . ChrCon <$> tokChar <|> Lit . StrCon <$> tokStr
varId = fmap ck $ liftA2 (:) small $ many (small <|> large <|> digit <|> char '\'') where
  ck s = (if elem s
    ["ffi", "export", "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "_"]
    then Reserved else VarId) s
varSym = fmap ck $ (:) <$> sat (\c -> isSymbol c && c /= ':') <*> many (sat isSymbol) where
  ck s = (if elem s ["..", "=", "\\", "|", "<-", "->", "@", "~", "=>"] then Reserved else VarSym) s

conId = fmap ConId $ liftA2 (:) large $ many (small <|> large <|> digit <|> char '\'')
conSym = fmap ck $ liftA2 (:) (char ':') $ many $ sat isSymbol where
  ck s = (if elem s [":", "::"] then Reserved else ConSym) s
special = Reserved . (:"") <$> asum (char <$> "(),;[]`{}")

rawBody = (char '|' *> char ']' *> pure []) <|> (:) <$> sat (const True) <*> rawBody
rawQQ = char '[' *> char 'r' *> char '|' *> (Lit . StrCon <$> rawBody)
lexeme = rawQQ <|> varId <|> varSym <|> conId <|> conSym
  <|> special <|> literal

whitespace = many (sat isSpace <|> comment)
lexemes = whitespace *> many (lexeme <* whitespace)

getPos = Lexer \st@(LexState _ rc) -> Right (rc, st)
posLexemes = whitespace *> many (liftA2 (,) getPos lexeme <* whitespace)

-- Layout.
data Landin = Curly Int | Angle Int | PL ((Int, Int), Token)
beginLayout xs = case xs of
  [] -> [Curly 0]
  ((r', _), Reserved "{"):_ -> margin r' xs
  ((r', c'), _):_ -> Curly c' : margin r' xs

landin ls@(((r, _), Reserved "{"):_) = margin r ls
landin ls@(((r, c), _):_) = Curly c : margin r ls
landin [] = []

margin r ls@(((r', c), _):_) | r /= r' = Angle c : embrace ls
margin r ls = embrace ls

embrace ls@(x@(_, Reserved w):rest) | elem w ["let", "where", "do", "of"] =
  PL x : beginLayout rest
embrace ls@(x@(_, Reserved "\\"):y@(_, Reserved "case"):rest) =
  PL x : PL y : beginLayout rest
embrace (x@((r,_),_):xt) = PL x : margin r xt
embrace [] = []

data Ell = Ell [Landin] [Int]
insPos x ts ms = Right (x, Ell ts ms)
ins w = insPos ((0, 0), Reserved w)

ell (Ell toks cols) = case toks of
  t:ts -> case t of
    Angle n -> case cols of
      m:ms | m == n -> ins ";" ts (m:ms)
           | n + 1 <= m -> ins "}" (Angle n:ts) ms
      _ -> ell $ Ell ts cols
    Curly n -> case cols of
      m:ms | m + 1 <= n -> ins "{" ts (n:m:ms)
      [] | 1 <= n -> ins "{" ts [n]
      _ -> ell $ Ell (PL ((0,0),Reserved "{"): PL ((0,0),Reserved "}"):Angle n:ts) cols
    PL x -> case snd x of
      Reserved "}" -> case cols of
        0:ms -> ins "}" ts ms
        _ -> Left "unmatched }"
      Reserved "{" -> insPos x ts (0:cols)
      _ -> insPos x ts cols
  [] -> case cols of
    [] -> Left "EOF"
    m:ms | m /= 0 -> ins "}" [] ms
    _ -> Left "missing }"

parseErrorRule (Ell toks cols) = case cols of
  m:ms | m /= 0 -> Right $ Ell toks ms
  _ -> Left "missing }"

-- Parser.
data ParseState = ParseState Ell (Map String (Int, Assoc))
data Parser a = Parser (ParseState -> Either String (a, ParseState))
getPrecs = Parser \st@(ParseState _ precs) -> Right (precs, st)
putPrecs precs = Parser \(ParseState s _) -> Right ((), ParseState s precs)
parse (Parser f) inp = f inp
instance Functor Parser where fmap f x = pure f <*> x
instance Applicative Parser where
  pure x = Parser \inp -> Right (x, inp)
  x <*> y = Parser \inp -> case parse x inp of
    Left e -> Left e
    Right (fun, t) -> case parse y t of
      Left e -> Left e
      Right (arg, u) -> Right (fun arg, u)
instance Monad Parser where
  return = pure
  (>>=) x f = Parser \inp -> case parse x inp of
    Left e -> Left e
    Right (a, t) -> parse (f a) t
instance Alternative Parser where
  empty = Parser \_ -> Left ""
  x <|> y = Parser \inp -> either (const $ parse y inp) Right $ parse x inp

ro = E . Basic . comEnum
conOf (Constr s _) = s
specialCase (h:_) = '|':conOf h
mkCase t cs = (specialCase cs,
  ( noQual $ arr t $ foldr arr (TV "case") $ map (\(Constr _ sts) -> foldr arr (TV "case") $ snd <$> sts) cs
  , ro "I"))
mkStrs = snd . foldl (\(s, l) u -> ('@':s, s:l)) ("@", [])
scottEncode _ ":" _ = ro "CONS"
scottEncode vs s ts = foldr L (foldl (\a b -> A a (V b)) (V s) ts) (ts ++ vs)
scottConstr t cs (Constr s sts) = (s,
  (noQual $ foldr arr t ts , scottEncode (map conOf cs) s $ mkStrs ts))
  : [(field, (noQual $ t `arr` ft, L s $ foldl A (V s) $ inj $ proj field)) | (field, ft) <- sts, field /= ""]
  where
  ts = snd <$> sts
  proj fd = foldr L (V fd) $ fst <$> sts
  inj x = map (\(Constr s' _) -> if s' == s then x else V "undefined") cs
mkAdtDefs t cs = mkCase t cs : concatMap (scottConstr t cs) cs

mkFFIHelper n t acc = case t of
  TC s -> acc
  TAp (TC "IO") _ -> acc
  TAp (TAp (TC "->") x) y -> L (showInt n "") $ mkFFIHelper (n + 1) y $ A (V $ showInt n "") acc

updateDcs cs dcs = foldr (\(Constr s _) m -> insert s cs m) dcs cs
addAdt t cs ders (Neat tycl fs typed dcs ffis exs) = foldr derive ast ders where
  ast = Neat tycl fs (mkAdtDefs t cs ++ typed) (updateDcs cs dcs) ffis exs
  derive "Eq" = addInstance "Eq" (mkPreds "Eq") t
    [("==", L "lhs" $ L "rhs" $ Ca (V "lhs") $ map eqCase cs
    )]
  derive "Show" = addInstance "Show" (mkPreds "Show") t
    [("showsPrec", L "prec" $ L "x" $ Ca (V "x") $ map showCase cs
    )]
  derive der = error $ "bad deriving: " ++ der
  showCase (Constr con args) = let as = (`showInt` "") <$> [1..length args]
    in (PatCon con (mkPatVar "" <$> as), case args of
      [] -> L "s" $ A (A (V "++") (E $ StrCon con)) (V "s")
      _ -> case con of
        ':':_ -> A (A (V "showParen") $ V "True") $ foldr1
          (\f g -> A (A (V ".") f) g)
          [ A (A (V "showsPrec") (E $ Const 11)) (V "1")
          , L "s" $ A (A (V "++") (E $ StrCon $ ' ':con++" ")) (V "s")
          , A (A (V "showsPrec") (E $ Const 11)) (V "2")
          ]
        _ -> A (A (V "showParen") $ A (A (V "<=") (E $ Const 11)) $ V "prec") $ foldr
          (\f g -> A (A (V ".") f) g)
          (L "s" $ A (A (V "++") (E $ StrCon con)) (V "s"))
          $ map (\a -> A (A (V ".") (A (V ":") (E $ ChrCon ' '))) $ A (A (V "showsPrec") (E $ Const 11)) (V a)) as
      )
  mkPreds classId = Pred classId . TV <$> typeVars t
  mkPatVar pre s = PatVar (pre ++ s) Nothing
  eqCase (Constr con args) = let as = (`showInt` "") <$> [1.. length args]
    in (PatCon con (mkPatVar "l" <$> as), Ca (V "rhs")
      [ (PatCon con (mkPatVar "r" <$> as), foldr (\x y -> (A (A (V "&&") x) y)) (V "True")
         $ map (\n -> A (A (V "==") (V $ "l" ++ n)) (V $ "r" ++ n)) as)
      , (PatVar "_" Nothing, V "False")])

emptyTycl = Tycl [] []
addClass classId v (sigs, defs) (Neat tycl fs typed dcs ffis exs) = let
  vars = (`showInt` "") <$> [1..size sigs]
  selectors = zipWith (\var (s, Qual ps t) -> (s, (Qual (Pred classId v:ps) t,
    L "@" $ A (V "@") $ foldr L (V var) vars))) vars $ toAscList sigs
  methods = map (\s -> (s, mlookup s defs)) $ fst <$> toAscList sigs
  Tycl _ is = maybe emptyTycl id $ mlookup classId tycl
  tycl' = insert classId (Tycl methods is) tycl
  in Neat tycl' fs (selectors ++ typed) dcs ffis exs

addInstance classId ps ty ds (Neat tycl fs typed dcs ffis exs) = let
  Tycl ms is = maybe emptyTycl id $ mlookup classId tycl
  tycl' = insert classId (Tycl ms $ Instance ty name ps (fromList ds):is) tycl
  name = '{':classId ++ (' ':showType ty "") ++ "}"
  in Neat tycl' fs typed dcs ffis exs

addFFI foreignname ourname t (Neat tycl fs typed dcs ffis exs) =
  Neat tycl fs ((ourname, (Qual [] t, mkFFIHelper 0 t $ A (ro "F") (E $ Basic $ length ffis))) : typed) dcs ((foreignname, t):ffis) exs
addTopDecl decl (Neat tycl (fs, decls) typed dcs ffis exs) =
  Neat tycl (fs, decl:decls) typed dcs ffis exs
addDefs ds (Neat tycl fs typed dcs ffis exs) = Neat tycl (first (ds++) fs) typed dcs ffis exs
addExport e f (Neat tycl fs typed dcs ffis exs) = Neat tycl fs typed dcs ffis ((e, f):exs)

want f = Parser \(ParseState inp precs) -> case ell inp of
  Right ((_, x), inp') -> (, ParseState inp' precs) <$> f x
  Left e -> Left e

braceYourself = Parser \(ParseState inp precs) -> case ell inp of
  Right ((_, Reserved "}"), inp') -> Right ((), ParseState inp' precs)
  _ -> case parseErrorRule inp of
    Left e -> Left e
    Right inp' -> Right ((), ParseState inp' precs)

res w = want \case
  Reserved s | s == w -> Right s
  _ -> Left $ "want \"" ++ w ++ "\""
wantInt = want \case
  Lit (Const i) -> Right i
  _ -> Left "want integer"
wantString = want \case
  Lit (StrCon s) -> Right s
  _ -> Left "want string"
wantConId = want \case
  ConId s -> Right s
  _ -> Left "want conid"
wantVarId = want \case
  VarId s -> Right s
  _ -> Left "want varid"
wantVarSym = want \case
  VarSym s -> Right s
  _ -> Left "want VarSym"
wantLit = want \case
  Lit x -> Right x
  _ -> Left "want literal"

paren = between (res "(") (res ")")
braceSep f = between (res "{") braceYourself $ foldr ($) [] <$> sepBy ((:) <$> f <|> pure id) (res ";")

maybeFix s x = if elem s $ fvPro [] x then A (V "fix") (L s x) else x

coalesce ds = flst ds [] \h@(s, x) t -> flst t [h] \(s', x') t' -> let
  f (Pa vsts) (Pa vsts') = Pa $ vsts ++ vsts'
  f _ _ = error "bad multidef"
  in if s == s' then coalesce $ (s, f x x'):t' else h:coalesce t

nonemptyTails [] = []
nonemptyTails xs@(x:xt) = xs : nonemptyTails xt

addLets ls x = foldr triangle x components where
  vs = fst <$> ls
  ios = foldr (\(s, dsts) (ins, outs) ->
    (foldr (\dst -> insertWith union dst [s]) ins dsts, insertWith union s dsts outs))
    (Tip, Tip) $ map (\(s, t) -> (s, intersect (fvPro [] t) vs)) ls
  components = scc (\k -> maybe [] id $ mlookup k $ fst ios) (\k -> maybe [] id $ mlookup k $ snd ios) vs
  triangle names expr = let
    tnames = nonemptyTails names
    suball t = foldr (\(x:xt) t -> overFreePro x (const $ foldl (\acc s -> A acc (V s)) (V x) xt) t) t tnames
    insLams vs t = foldr L t vs
    in foldr (\(x:xt) t -> A (L x t) $ maybeFix x $ insLams xt $ suball $ maybe undefined id $ lookup x ls) (suball expr) tnames

data Assoc = NAssoc | LAssoc | RAssoc deriving Eq
precOf s precTab = maybe 5 fst $ mlookup s precTab
assocOf s precTab = maybe LAssoc snd $ mlookup s precTab

parseErr s = Parser $ const $ Left s

opFold precTab f x xs = case xs of
  [] -> pure x
  (op, y):xt -> case find (\(op', _) -> assocOf op precTab /= assocOf op' precTab) xt of
    Nothing -> case assocOf op precTab of
      NAssoc -> case xt of
        [] -> pure $ f op x y
        y:yt -> parseErr "NAssoc repeat"
      LAssoc -> pure $ foldl (\a (op, y) -> f op a y) x xs
      RAssoc -> pure $ foldr (\(op, y) b -> \e -> f op e (b y)) id xs $ x
    Just y -> parseErr "Assoc clash"

qconop = want f <|> between (res "`") (res "`") (want g) where
  f (ConSym s) = Right s
  f (Reserved ":") = Right ":"
  f _ = Left ""
  g (ConId s) = Right s
  g _ = Left "want qconop"

wantqconsym = want \case
  ConSym s -> Right s
  Reserved ":" -> Right ":"
  _ -> Left "want qconsym"

op = wantqconsym <|> want f <|> between (res "`") (res "`") (want g) where
  f (VarSym s) = Right s
  f _ = Left ""
  g (VarId s) = Right s
  g (ConId s) = Right s
  g _ = Left "want op"

con = wantConId <|> paren wantqconsym
var = wantVarId <|> paren wantVarSym

tycon = want \case
  ConId s -> Right $ if s == "String" then TAp (TC "[]") (TC "Char") else TC s
  _ -> Left "want type constructor"

aType =
  res "(" *>
    (   res ")" *> pure (TC "()")
    <|> (foldr1 (TAp . TAp (TC ",")) <$> sepBy1 _type (res ",")) <* res ")")
  <|> tycon
  <|> TV <$> wantVarId
  <|> (res "[" *> (res "]" *> pure (TC "[]") <|> TAp (TC "[]") <$> (_type <* res "]")))
bType = foldl1 TAp <$> some aType
_type = foldr1 arr <$> sepBy bType (res "->")

fixityDecl w a = do
  res w
  n <- fromIntegral <$> wantInt
  os <- sepBy op (res ",")
  precs <- getPrecs
  putPrecs $ foldr (\o m -> insert o (n, a) m) precs os
fixity = fixityDecl "infix" NAssoc <|> fixityDecl "infixl" LAssoc <|> fixityDecl "infixr" RAssoc

cDecls = first fromList . second (fromList . coalesce) . foldr ($) ([], []) <$> braceSep cDecl
cDecl = first . (:) <$> genDecl <|> second . (++) <$> def

genDecl = (,) <$> var <* res "::" <*> (Qual <$> (scontext <* res "=>" <|> pure []) <*> _type)

classDecl = res "class" *> (addClass <$> wantConId <*> (TV <$> wantVarId) <*> (res "where" *> cDecls))

simpleClass = Pred <$> wantConId <*> _type
scontext = (:[]) <$> simpleClass <|> paren (sepBy simpleClass $ res ",")

instDecl = res "instance" *>
  ((\ps cl ty defs -> addInstance cl ps ty defs) <$>
  (scontext <* res "=>" <|> pure [])
    <*> wantConId <*> _type <*> (res "where" *> (coalesce . concat <$> braceSep def)))

letin = addLets <$> between (res "let") (res "in") (coalesce . concat <$> braceSep def) <*> expr
ifthenelse = (\a b c -> A (A (A (V "if") a) b) c) <$>
  (res "if" *> expr) <*> (res "then" *> expr) <*> (res "else" *> expr)
listify = foldr (\h t -> A (A (V ":") h) t) (V "[]")

alts = braceSep $ (,) <$> pat <*> caseGuards
cas = Ca <$> between (res "case") (res "of") expr <*> alts
lamCase = res "case" *> (L "\\case" . Ca (V "\\case") <$> alts)
lam = res "\\" *> (lamCase <|> liftA2 onePat (some apat) (res "->" *> expr))

flipPairize y x = A (A (V ",") x) y
moreCommas = foldr1 (A . A (V ",")) <$> sepBy1 expr (res ",")
thenComma = res "," *> ((flipPairize <$> moreCommas) <|> pure (A (V ",")))
parenExpr = (&) <$> expr <*> (((\v a -> A (V v) a) <$> op) <|> thenComma <|> pure id)
rightSect = ((\v a -> L "@" $ A (A (V v) $ V "@") a) <$> (op <|> res ",")) <*> expr
section = res "(" *> (parenExpr <* res ")" <|> rightSect <* res ")" <|> res ")" *> pure (V "()"))

maybePureUnit = maybe (V "pure" `A` V "()") id
stmt = (\p x -> Just . A (V ">>=" `A` x) . onePat [p] . maybePureUnit) <$> pat <*> (res "<-" *> expr)
  <|> (\x -> Just . maybe x (\y -> (V ">>=" `A` x) `A` (L "_" y))) <$> expr
  <|> (\ds -> Just . addLets ds . maybePureUnit) <$> (res "let" *> (coalesce . concat <$> braceSep def))
doblock = res "do" *> (maybePureUnit . foldr ($) Nothing <$> braceSep stmt)

compQual =
  (\p xs e -> A (A (V "concatMap") $ onePat [p] e) xs)
    <$> pat <*> (res "<-" *> expr)
  <|> (\b e -> A (A (A (V "if") b) e) $ V "[]") <$> expr
  <|> addLets <$> (res "let" *> (coalesce . concat <$> braceSep def))

sqExpr = between (res "[") (res "]") $
  ((&) <$> expr <*>
    (   res ".." *>
      (   (\hi lo -> (A (A (V "enumFromTo") lo) hi)) <$> expr
      <|> pure (A (V "enumFrom"))
      )
    <|> res "|" *>
      ((. A (V "pure")) . foldr (.) id <$> sepBy1 compQual (res ","))
    <|> (\t h -> listify (h:t)) <$> many (res "," *> expr)
    )
  ) <|> pure (V "[]")

atom = ifthenelse <|> doblock <|> letin <|> sqExpr <|> section
  <|> cas <|> lam <|> (paren (res ",") *> pure (V ","))
  <|> fmap V (con <|> var) <|> E <$> wantLit

aexp = foldl1 A <$> some atom

withPrec precTab n p = p >>= \s ->
  if n == precOf s precTab then pure s else Parser $ const $ Left ""

exprP n = if n <= 9
  then getPrecs >>= \precTab
    -> exprP (succ n) >>= \a
    -> many ((,) <$> withPrec precTab n op <*> exprP (succ n)) >>= \as
    -> opFold precTab (\op x y -> A (A (V op) x) y) a as
  else aexp
expr = exprP 0

gcon = wantConId <|> paren (wantqconsym <|> res ",") <|> ((++) <$> res "[" <*> (res "]"))

apat = PatVar <$> var <*> (res "@" *> (Just <$> apat) <|> pure Nothing)
  <|> flip PatVar Nothing <$> (res "_" *> pure "_")
  <|> flip PatCon [] <$> gcon
  <|> PatLit <$> wantLit
  <|> foldr (\h t -> PatCon ":" [h, t]) (PatCon "[]" [])
    <$> between (res "[") (res "]") (sepBy pat $ res ",")
  <|> paren (foldr1 pairPat <$> sepBy1 pat (res ",") <|> pure (PatCon "()" []))
  where pairPat x y = PatCon "," [x, y]

binPat f x y = PatCon f [x, y]
patP n = if n <= 9
  then getPrecs >>= \precTab
    -> patP (succ n) >>= \a
    -> many ((,) <$> withPrec precTab n qconop <*> patP (succ n)) >>= \as
    -> opFold precTab binPat a as
  else PatCon <$> gcon <*> many apat <|> apat
pat = patP 0

maybeWhere p = (&) <$> p <*> (res "where" *> (addLets . coalesce . concat <$> braceSep def) <|> pure id)

guards s v = maybeWhere $ res s *> expr <|> foldr ($) v <$> some ((\x y -> case x of
  V "True" -> \_ -> y
  _ -> A (A (A (V "if") x) y)
  ) <$> (res "|" *> expr) <*> (res s *> expr))
eqGuards = guards "=" $ V "pjoin#"
caseGuards = guards "->" $ V "cjoin#"
onePat vs x = Pa [(vs, x)]
opDef x f y rhs = [(f, onePat [x, y] rhs)]
leftyPat p expr = case patVars p of
  [] -> []
  (h:t) -> let gen = '@':h in
    (gen, expr):map (\v -> (v, Ca (V gen) [(p, V v)])) (patVars p)
def = liftA2 (\l r -> [(l, r)]) var (onePat <$> many apat <*> eqGuards)
  <|> (pat >>= \x -> opDef x <$> wantVarSym <*> pat <*> eqGuards <|> leftyPat x <$> eqGuards)

simpleType c vs = foldl TAp (TC c) (map TV vs)
conop = want f <|> between (res "`") (res "`") (want g) where
  f (ConSym s) = Right s
  f _ = Left ""
  g (ConId s) = Right s
  g _ = Left "want conop"

vars = sepBy1 var $ res ","
fieldDecl = (\vs t -> map (, t) vs) <$> vars <*> (res "::" *> _type)
constr = (\x c y -> Constr c [("", x), ("", y)]) <$> aType <*> conop <*> aType
  <|> Constr <$> wantConId <*>
    (   concat <$> between (res "{") (res "}") (fieldDecl `sepBy` res ",")
    <|> map ("",) <$> many aType)
dclass = wantConId
_deriving = (res "deriving" *> ((:[]) <$> dclass <|> paren (dclass `sepBy` res ","))) <|> pure []
adt = addAdt <$> between (res "data") (res "=") (simpleType <$> wantConId <*> many wantVarId) <*> sepBy constr (res "|") <*> _deriving

topdecls = braceSep
  (   adt
  <|> classDecl
  <|> addTopDecl <$> genDecl
  <|> instDecl
  <|> res "ffi" *> (addFFI <$> wantString <*> var <*> (res "::" *> _type))
  <|> res "export" *> (addExport <$> wantString <*> var)
  <|> addDefs <$> def
  <|> fixity *> pure id
  )

offside xs = Ell (landin xs) []
program s = case lex posLexemes $ LexState s (1, 1) of
  Left e -> Left e
  Right (xs, LexState [] _) -> parse topdecls $ ParseState (offside xs) $ insert ":" (5, RAssoc) Tip
  Right (_, st) -> Left "unlexable"

-- Primitives.
primAdts =
  [ addAdt (TC "()") [Constr "()" []] []
  , addAdt (TC "Bool") [Constr "True" [], Constr "False" []] ["Eq"]
  , addAdt (TAp (TC "[]") (TV "a")) [Constr "[]" [], Constr ":" [("", TV "a"), ("", TAp (TC "[]") (TV "a"))]] []
  , addAdt (TAp (TAp (TC ",") (TV "a")) (TV "b")) [Constr "," [("", TV "a"), ("", TV "b")]] []
  ]

prims = let
  dyad s = TC s `arr` (TC s `arr` TC s)
  wordy = foldr arr (TAp (TAp (TC ",") (TC "Word")) (TC "Word")) [TC "Word", TC "Word", TC "Word", TC "Word"]
  bin s = A (ro "Q") (ro s)
  in map (second (first noQual)) $
    [ ("intEq", (arr (TC "Int") (arr (TC "Int") (TC "Bool")), bin "EQ"))
    , ("intLE", (arr (TC "Int") (arr (TC "Int") (TC "Bool")), bin "LE"))
    , ("wordLE", (arr (TC "Word") (arr (TC "Word") (TC "Bool")), bin "U_LE"))
    , ("wordEq", (arr (TC "Word") (arr (TC "Word") (TC "Bool")), bin "EQ"))
    , ("charEq", (arr (TC "Char") (arr (TC "Char") (TC "Bool")), bin "EQ"))
    , ("charLE", (arr (TC "Char") (arr (TC "Char") (TC "Bool")), bin "LE"))
    , ("fix", (arr (arr (TV "a") (TV "a")) (TV "a"), ro "Y"))
    , ("if", (arr (TC "Bool") $ arr (TV "a") $ arr (TV "a") (TV "a"), ro "I"))
    , ("intFromWord", (arr (TC "Word") (TC "Int"), ro "I"))
    , ("wordFromInt", (arr (TC "Int") (TC "Word"), ro "I"))
    , ("chr", (arr (TC "Int") (TC "Char"), ro "I"))
    , ("ord", (arr (TC "Char") (TC "Int"), ro "I"))
    , ("ioBind", (arr (TAp (TC "IO") (TV "a")) (arr (arr (TV "a") (TAp (TC "IO") (TV "b"))) (TAp (TC "IO") (TV "b"))), ro "C"))
    , ("ioPure", (arr (TV "a") (TAp (TC "IO") (TV "a")), A (A (ro "B") (ro "C")) (ro "T")))
    , ("newIORef", (arr (TV "a") (TAp (TC "IO") (TAp (TC "IORef") (TV "a"))),
      A (A (ro "B") (ro "C")) (A (A (ro "B") (ro "T")) (ro "REF"))))
    , ("readIORef", (arr (TAp (TC "IORef") (TV "a")) (TAp (TC "IO") (TV "a")),
      A (ro "T") (ro "READREF")))
    , ("writeIORef", (arr (TAp (TC "IORef") (TV "a")) (arr (TV "a") (TAp (TC "IO") (TC "()"))),
      A (A (ro "R") (ro "WRITEREF")) (ro "B")))
    , ("exitSuccess", (TAp (TC "IO") (TV "a"), ro "END"))
    , ("unsafePerformIO", (arr (TAp (TC "IO") (TV "a")) (TV "a"), A (A (ro "C") (A (ro "T") (ro "END"))) (ro "K")))
    , ("fail#", (TV "a", A (V "unsafePerformIO") (V "exitSuccess")))
    , ("word64Add", (wordy, A (ro "QQ") (ro "DADD")))
    , ("word64Sub", (wordy, A (ro "QQ") (ro "DSUB")))
    , ("word64Mul", (wordy, A (ro "QQ") (ro "DMUL")))
    , ("word64Div", (wordy, A (ro "QQ") (ro "DDIV")))
    , ("word64Mod", (wordy, A (ro "QQ") (ro "DMOD")))
    ]
    ++ map (\(s, v) -> (s, (dyad "Int", bin v)))
      [ ("intAdd", "ADD")
      , ("intSub", "SUB")
      , ("intMul", "MUL")
      , ("intDiv", "DIV")
      , ("intMod", "MOD")
      , ("intQuot", "QUOT")
      , ("intRem", "REM")
      ]
    ++ map (\(s, v) -> (s, (dyad "Word", bin v)))
      [ ("wordAdd", "ADD")
      , ("wordSub", "SUB")
      , ("wordMul", "MUL")
      , ("wordDiv", "U_DIV")
      , ("wordMod", "U_MOD")
      , ("wordQuot", "U_DIV")
      , ("wordRem", "U_MOD")
      ]

-- Conversion to De Bruijn indices.
data LC = Ze | Su LC | Pass Extra | PassVar String | La LC | App LC LC

debruijn n e = case e of
  E x -> Pass x
  V v -> maybe (PassVar v) id $
    foldr (\h found -> if h == v then Just Ze else Su <$> found) Nothing n
  A x y -> App (debruijn n x) (debruijn n y)
  L s t -> La (debruijn (s:n) t)

-- Kiselyov bracket abstraction.
data IntTree = Lf Extra | LfVar String | Nd IntTree IntTree
data Sem = Defer | Closed IntTree | Need Sem | Weak Sem

lf = Lf . Basic . comEnum

ldef y = case y of
  Defer -> Need $ Closed (Nd (Nd (lf "S") (lf "I")) (lf "I"))
  Closed d -> Need $ Closed (Nd (lf "T") d)
  Need e -> Need $ (Closed (Nd (lf "S") (lf "I"))) ## e
  Weak e -> Need $ (Closed (lf "T")) ## e

lclo d y = case y of
  Defer -> Need $ Closed d
  Closed dd -> Closed $ Nd d dd
  Need e -> Need $ (Closed (Nd (lf "B") d)) ## e
  Weak e -> Weak $ (Closed d) ## e

lnee e y = case y of
  Defer -> Need $ Closed (lf "S") ## e ## Closed (lf "I")
  Closed d -> Need $ Closed (Nd (lf "R") d) ## e
  Need ee -> Need $ Closed (lf "S") ## e ## ee
  Weak ee -> Need $ Closed (lf "C") ## e ## ee

lwea e y = case y of
  Defer -> Need e
  Closed d -> Weak $ e ## Closed d
  Need ee -> Need $ (Closed (lf "B")) ## e ## ee
  Weak ee -> Weak $ e ## ee

x ## y = case x of
  Defer -> ldef y
  Closed d -> lclo d y
  Need e -> lnee e y
  Weak e -> lwea e y

babs t = case t of
  Ze -> Defer
  Su x -> Weak (babs x)
  Pass x -> Closed (Lf x)
  PassVar s -> Closed (LfVar s)
  La t -> case babs t of
    Defer -> Closed (lf "I")
    Closed d -> Closed (Nd (lf "K") d)
    Need e -> e
    Weak e -> Closed (lf "K") ## e
  App x y -> babs x ## babs y

nolam x = (\(Closed d) -> d) $ babs $ debruijn [] x

isLeaf (Lf (Basic n)) c = n == comEnum c
isLeaf _ _ = False

optim t = case t of
  Nd x y -> let p = optim x ; q = optim y in
    if isLeaf p "I" then q else
    if isLeaf q "I" then case p of
      Lf (Basic c)
        | c == comEnum "C" -> lf "T"
        | c == comEnum "B" -> lf "I"
      Nd p1 p2 -> case p1 of
        Lf (Basic c)
          | c == comEnum "B" -> p2
          | c == comEnum "R" -> Nd (lf "T") p2
        _ -> Nd (Nd p1 p2) q
      _ -> Nd p q
    else if isLeaf q "T" then case p of
      Nd x y -> if isLeaf x "B" && isLeaf y "C" then lf "V" else Nd p q
      _ -> Nd p q
    else Nd p q
  _ -> t

freeCount v expr = case expr of
  E _ -> 0
  V s -> if s == v then 1 else 0
  A x y -> freeCount v x + freeCount v y
  L w t -> if v == w then 0 else freeCount v t
app01 s x = case freeCount s x of
  0 -> const x
  1 -> flip (beta s) x
  _ -> A $ L s x
optiApp t = case t of
  A (L s x) y -> app01 s (optiApp x) (optiApp y)
  A x y -> A (optiApp x) (optiApp y)
  L s x -> L s (optiApp x)
  _ -> t

-- Pattern compiler.
singleOut s cs = \scrutinee x ->
  foldl A (A (V $ specialCase cs) scrutinee) $ map (\(Constr s' ts) ->
    if s == s' then x else foldr L (V "pjoin#") $ map (const "_") ts) cs

patEq lit b x y = A (A (A (V "if") (A (A (V "==") lit') b)) x) y where
  lit' = case lit of
    Const _ -> A (V "fromInteger") (E lit)
    _ -> E lit

unpat dcs as t = case as of
  [] -> pure t
  a:at -> get >>= \n -> put (n + 1) >> let freshv = showInt n "#" in L freshv <$> let
    go p x = case p of
      PatLit lit -> unpat dcs at $ patEq lit (V freshv) x $ V "pjoin#"
      PatVar s m -> maybe (unpat dcs at) (\p1 x1 -> go p1 x1) m $ beta s (V freshv) x
      PatCon con args -> case mlookup con dcs of
        Nothing -> error "bad data constructor"
        Just cons -> unpat dcs args x >>= \y -> unpat dcs at $ singleOut con cons (V freshv) y
    in go a t

unpatTop dcs als x = case als of
  [] -> pure x
  (a, l):alt -> let
    go p t = case p of
      PatLit lit -> unpatTop dcs alt $ patEq lit (V l) t $ V "pjoin#"
      PatVar s m -> maybe (unpatTop dcs alt) go m $ beta s (V l) t
      PatCon con args -> case mlookup con dcs of
        Nothing -> error "bad data constructor"
        Just cons -> unpat dcs args t >>= \y -> unpatTop dcs alt $ singleOut con cons (V l) y
    in go a x

rewritePats' dcs asxs ls = case asxs of
  [] -> pure $ V "fail#"
  (as, t):asxt -> unpatTop dcs (zip as ls) t >>=
    \y -> A (L "pjoin#" y) <$> rewritePats' dcs asxt ls

rewritePats dcs vsxs@((vs0, _):_) = get >>= \n -> let
  ls = map (flip showInt "#") $ take (length vs0) [n..]
  in put (n + length ls) >> flip (foldr L) ls <$> rewritePats' dcs vsxs ls

classifyAlt v x = case v of
  PatLit lit -> Left $ patEq lit (V "of") x
  PatVar s m -> maybe (Left . A . L "cjoin#") classifyAlt m $ A (L s x) $ V "of"
  PatCon s ps -> Right (insertWith (flip (.)) s ((ps, x):))

genCase dcs tab = if size tab == 0 then id else A . L "cjoin#" $ let
  firstC = flst (toAscList tab) undefined (\h _ -> fst h)
  cs = maybe (error $ "bad constructor: " ++ firstC) id $ mlookup firstC dcs
  in foldl A (A (V $ specialCase cs) (V "of"))
    $ map (\(Constr s ts) -> case mlookup s tab of
      Nothing -> foldr L (V "cjoin#") $ const "_" <$> ts
      Just f -> Pa $ f [(const (PatVar "_" Nothing) <$> ts, V "cjoin#")]
    ) cs

updateCaseSt dcs (acc, tab) alt = case alt of
  Left f -> (acc . genCase dcs tab . f, Tip)
  Right upd -> (acc, upd tab)

rewriteCase dcs as = acc . genCase dcs tab $ V "fail#" where
  (acc, tab) = foldl (updateCaseSt dcs) (id, Tip) $ uncurry classifyAlt <$> as

secondM f (a, b) = (a,) <$> f b
-- Compiles patterns. Overloads literals.
patternCompile dcs t = optiApp $ evalState (go t) 0 where
  go t = case t of
    E (Const c) -> pure $ A (V "fromInteger") t
    E _ -> pure t
    V _ -> pure t
    A x y -> liftA2 A (go x) (go y)
    L s x -> L s <$> go x
    Pa vsxs -> mapM (secondM go) vsxs >>= rewritePats dcs
    Ca x as -> liftA2 A (L "of" . rewriteCase dcs <$> mapM (secondM go) as >>= go) (go x)

-- Unification and matching.
apply sub t = case t of
  TC v -> t
  TV v -> maybe t id $ lookup v sub
  TAp a b -> TAp (apply sub a) (apply sub b)

(@@) s1 s2 = map (second (apply s1)) s2 ++ s1

occurs s t = case t of
  TC v -> False
  TV v -> s == v
  TAp a b -> occurs s a || occurs s b

varBind s t = case t of
  TC v -> Right [(s, t)]
  TV v -> Right $ if v == s then [] else [(s, t)]
  TAp a b -> if occurs s t then Left "occurs check" else Right [(s, t)]

ufail t u = Left $ ("unify fail: "++) . showType t . (" vs "++) . showType u $ ""

mgu t u = case t of
  TC a -> case u of
    TC b -> if a == b then Right [] else ufail t u
    TV b -> varBind b t
    TAp a b -> ufail t u
  TV a -> varBind a u
  TAp a b -> case u of
    TC b -> ufail t u
    TV b -> varBind b t
    TAp c d -> mgu a c >>= unify b d

unify a b s = (@@ s) <$> mgu (apply s a) (apply s b)

merge s1 s2 = if all (\v -> apply s1 (TV v) == apply s2 (TV v))
  $ map fst s1 `intersect` map fst s2 then Just $ s1 ++ s2 else Nothing

match h t = case h of
  TC a -> case t of
    TC b | a == b -> Just []
    _ -> Nothing
  TV a -> Just [(a, t)]
  TAp a b -> case t of
    TAp c d -> case match a c of
      Nothing -> Nothing
      Just ac -> case match b d of
        Nothing -> Nothing
        Just bd -> merge ac bd
    _ -> Nothing

-- Type inference.
instantiate' t n tab = case t of
  TC s -> ((t, n), tab)
  TV s -> case lookup s tab of
    Nothing -> let va = TV (showInt n "") in ((va, n + 1), (s, va):tab)
    Just v -> ((v, n), tab)
  TAp x y ->
    fpair (instantiate' x n tab) \(t1, n1) tab1 ->
    fpair (instantiate' y n1 tab1) \(t2, n2) tab2 ->
    ((TAp t1 t2, n2), tab2)

instantiatePred (Pred s t) ((out, n), tab) = first (first ((:out) . Pred s)) (instantiate' t n tab)

instantiate (Qual ps t) n =
  fpair (foldr instantiatePred (([], n), []) ps) \(ps1, n1) tab ->
  first (Qual ps1) (fst (instantiate' t n1 tab))

proofApply sub a = case a of
  Proof (Pred cl ty) -> Proof (Pred cl $ apply sub ty)
  A x y -> A (proofApply sub x) (proofApply sub y)
  L s t -> L s $ proofApply sub t
  _ -> a

typeAstSub sub (t, a) = (apply sub t, proofApply sub a)

infer typed loc ast csn@(cs, n) = let
  va = TV (showInt n "")
  insta ty = fpair (instantiate ty n) \(Qual preds ty) n1 -> ((ty, foldl A ast (map Proof preds)), (cs, n1))
  in case ast of
    E x -> Right $ case x of
      Const _ -> ((TC "Integer",  ast), csn)
      ChrCon _ -> ((TC "Char",  ast), csn)
      StrCon _ -> ((TAp (TC "[]") (TC "Char"),  ast), csn)
    V s -> maybe (Left $ "undefined: " ++ s) Right
      $ (\t -> ((t, ast), csn)) <$> lookup s loc
      <|> insta <$> mlookup s typed
    A x y -> infer typed loc x (cs, n + 1) >>=
      \((tx, ax), csn1) -> infer typed loc y csn1 >>=
      \((ty, ay), (cs2, n2)) -> unify tx (arr ty va) cs2 >>=
      \cs -> Right ((va, A ax ay), (cs, n2))
    L s x -> first (\(t, a) -> (arr va t, L s a)) <$> infer typed ((s, va):loc) x (cs, n + 1)

findInstance tycl qn@(q, n) p@(Pred cl ty) insts = case insts of
  [] -> let v = '*':showInt n "" in Right (((p, v):q, n + 1), V v)
  Instance h name ps _:rest -> case match h ty of
    Nothing -> findInstance tycl qn p rest
    Just subs -> foldM (\(qn1, t) (Pred cl1 ty1) -> second (A t)
      <$> findProof tycl (Pred cl1 $ apply subs ty1) qn1) (qn, V name) ps

findProof tycl pred@(Pred classId t) psn@(ps, n) = case lookup pred ps of
  Nothing -> case mlookup classId tycl of
    Nothing -> Left $ "no instance: " ++ showPred pred ""
    Just (Tycl _ insts) -> findInstance tycl psn pred insts
  Just s -> Right (psn, V s)

prove' tycl psn a = case a of
  Proof pred -> findProof tycl pred psn
  A x y -> prove' tycl psn x >>= \(psn1, x1) ->
    second (A x1) <$> prove' tycl psn1 y
  L s t -> second (L s) <$> prove' tycl psn t
  _ -> Right (psn, a)

depGraph typed (s, t) (vs, es) = (insert s t vs, foldr go es $ fv [] t) where
  go k ios@(ins, outs) = case lookup k typed of
    Nothing -> (insertWith union k [s] ins, insertWith union s [k] outs)
    Just _ -> ios

depthFirstSearch = (foldl .) \relation st@(visited, sequence) vertex ->
  if vertex `elem` visited then st else second (vertex:)
    $ depthFirstSearch relation (vertex:visited, sequence) (relation vertex)

spanningSearch   = (foldl .) \relation st@(visited, setSequence) vertex ->
  if vertex `elem` visited then st else second ((:setSequence) . (vertex:))
    $ depthFirstSearch relation (vertex:visited, []) (relation vertex)

scc ins outs = spanning . depthFirst where
  depthFirst = snd . depthFirstSearch outs ([], [])
  spanning   = snd . spanningSearch   ins  ([], [])

inferno prove typed defmap syms = let
  loc = zip syms (TV . (' ':) <$> syms)
  in foldM (\(acc, (subs, n)) s -> do
    expr <- maybe (Left $ "missing: " ++ s) Right (mlookup s defmap)
    ((t, a), (ms, n1)) <- either (Left . (s++) . (": "++)) Right
      $ infer typed loc expr (subs, n)
    cs <- unify (TV (' ':s)) t ms
    pure ((s, (t, a)):acc, (cs, n1))
  ) ([], ([], 0)) syms >>=
  \(stas, (soln, _)) -> mapM id $ (\(s, ta) -> prove s $ typeAstSub soln ta) <$> stas

insertList xs m = foldr (uncurry insert) m xs

prove tycl s (t, a) = flip fmap (prove' tycl ([], 0) a) \((ps, _), x) -> let
  applyDicts expr = foldl A expr $ map (V . snd) ps
  in (s, (Qual (map fst ps) t, foldr L (overFree s applyDicts x) $ map snd ps))

ambiguous (Qual ps t) = filter (not . resolvable) ps where
  resolvable (Pred _ ty) = all (`elem` typeVars t) $ typeVars ty

f *** g = \(x, y) -> (f x, g y)

defaultMagic tycl q@(Qual ps t) lamb = let
  ambis = ambiguous q
  rings = concatMap isRing ambis
  isRing (Pred "Ring" (TV v)) = [v]
  isRing _ = []
  defaultize lambSub [] lamb = Right ([], foldr (uncurry beta) lamb lambSub)
  defaultize lambSub (p:pt) (L s t) = case p of
    Pred cl (TV v) | v `elem` rings -> do
      (_, ast) <- findProof tycl (Pred cl $ TC "Integer") ([], 0)
      defaultize ((s, ast) : lambSub) pt t
    _ -> ((p:) *** (L s)) <$> defaultize lambSub pt t
  in case rings of
    [] -> Right (q, lamb)
    _ -> do
      (ps, lamb) <- defaultize [] ps lamb
      let q' = Qual ps t
      case ambiguous q' of
        [] -> Right (q', lamb)
        ambis -> Left $ ("ambiguous: "++) . foldr (.) id (map showPred ambis) $ ""

reconcile tycl q@(Qual ps t) lamb = \case
  Nothing -> defaultMagic tycl q lamb
  Just qAnno@(Qual psA tA) -> case match t tA of
    Nothing -> Left $ "type mismatch, expected: " ++ showQual qAnno "" ++ ", actual: " ++ showQual q ""
    Just sub -> let
      vcount = length psA
      vars = map (`showInt` "") [1..vcount]
      annoDictVars = (zip psA vars, vcount)
      forbidNew p ((_, n), x)
        | n == vcount = Right x
        | True = Left $ "missing predicate: " ++ showPred p ""
      findAnno p@(Pred cl ty) = findProof tycl (Pred cl $ apply sub ty) annoDictVars >>= forbidNew p
      in do
        dicts <- mapM findAnno ps
        case ambiguous qAnno of
          [] -> pure (qAnno, foldr L (foldl A lamb dicts) vars)
          ambis -> Left $ ("ambiguous: "++) . foldr (.) id (map showPred ambis) $ ""

inferDefs' tycl decls defmap (typeTab, lambF) syms = let
  add (tt, f) (s, (q, lamb)) = do
    (q, lamb) <- either (Left . (s++) . (": "++)) Right
      $ reconcile tycl q lamb $ lookup s decls
    pure (insert s q tt, f . ((s, lamb):))
  in inferno (prove tycl) (insertList decls typeTab) defmap syms >>= foldM add (typeTab, lambF)

inferDefs tycl decls defs typed = let
  typeTab = foldr (\(k, (q, _)) -> insert k q) Tip typed
  lambs = second snd <$> typed
  (defmap, graph) = foldr (depGraph typed) (Tip, (Tip, Tip)) defs
  ins k = maybe [] id $ mlookup k $ fst graph
  outs k = maybe [] id $ mlookup k $ snd graph
  in foldM (inferDefs' tycl decls defmap) (typeTab, (lambs++)) $ scc ins outs $ map fst $ toAscList defmap

dictVars ps n = (zip ps $ map (('*':) . flip showInt "") [n..], n + length ps)

inferTypeclasses tycl typed dcs = concat <$> mapM perClass (toAscList tycl) where
  perClass (classId, Tycl sigs insts) = do
    let
      checkDefault (s, Just expr) = do
        (ta, (sub, _)) <- either (Left . (s++) . (" (class): "++)) Right
          $ infer typed [] (patternCompile dcs expr) ([], 0)
        (_, (Qual ps t, a)) <- prove tycl s $ typeAstSub sub ta
        case ps of
          [Pred cl _] | cl == classId -> Right ()
          _ -> Left $ "bad method: " ++ s
        Qual ps0 t0 <- maybe (Left "parse bug!") Right $ mlookup s typed
        case match t t0 of
          Nothing -> Left $ "bad method type: " ++ s
          _ -> Right ()
      checkDefault (s, Nothing) = pure ()
    mapM_ checkDefault sigs
    let
      perInstance (Instance ty name ps idefs) = do
        let
          dvs = map snd $ fst $ dictVars ps 0
          perMethod (s, mayDefault) = do
            let Just expr = mlookup s idefs <|> mayDefault <|> pure (V "fail#")
            (ta, (sub, n)) <- either (Left . (name++) . (" "++) . (s++) . (": "++)) Right
              $ infer typed [] (patternCompile dcs expr) ([], 0)
            let
              (tx, ax) = typeAstSub sub ta
-- e.g. qc = Eq a => a -> a -> Bool
-- We instantiate: Eq a1 => a1 -> a1 -> Bool.
              Just qc = mlookup s typed
              (Qual [Pred _ headT] tc, n1) = instantiate qc n
-- Mix the predicates `ps` with the type of `headT`, applying a
-- substitution such as (a1, [a]) so the variable names match.
-- e.g. Eq a => [a] -> [a] -> Bool
              Just subc = match headT ty
              (Qual ps2 t2, n2) = instantiate (Qual ps $ apply subc tc) n1
            case match tx t2 of
              Nothing -> Left $ name ++ " class/instance type conflict"
              Just subx -> do
                ((ps3, _), tr) <- prove' tycl (dictVars ps2 0) (proofApply subx ax)
                if length ps2 /= length ps3
                  then Left $ ("want context: "++) . (foldr (.) id $ showPred . fst <$> ps3) $ name
                  else pure tr
        ms <- mapM perMethod sigs
        pure (name, flip (foldr L) dvs $ L "@" $ foldl A (V "@") ms)
    mapM perInstance insts

untangle s = case program s of
  Left e -> Left $ "parse error: " ++ e
  Right (prog, ParseState s _) -> case s of
    Ell [] [] -> case foldr ($) (customMods $ Neat Tip ([], []) prims Tip [] []) $ primAdts ++ prog of
      Neat tycl (defs, decls) typed dcs ffis exs -> do
        (qas, lambF) <- inferDefs tycl decls (second (patternCompile dcs) <$> coalesce defs) typed
        mets <- inferTypeclasses tycl qas dcs
        pure ((qas, lambF mets), (ffis, exs))
    _ -> Left $ "parse error: " ++ case ell s of
      Left e -> e
      Right (((r, c), _), _) -> ("row "++) . showInt r . (" col "++) . showInt c $ ""

optiComb' (subs, combs) (s, lamb) = let
  gosub t = case t of
    LfVar v -> maybe t id $ lookup v subs
    Nd a b -> Nd (gosub a) (gosub b)
    _ -> t
  c = optim $ gosub $ nolam $ optiApp lamb
  combs' = combs . ((s, c):)
  in case c of
    Lf (Basic _) -> ((s, c):subs, combs')
    LfVar v -> if v == s then (subs, combs . ((s, Nd (lf "Y") (lf "I")):)) else ((s, gosub c):subs, combs')
    _ -> (subs, combs')
optiComb lambs = ($[]) . snd $ foldl optiComb' ([], id) lambs

showVar s@(h:_) = showParen (elem h ":!#$%&*+./<=>?@\\^|-~") (s++)

showExtra = \case
  Basic i -> (comName i++)
  Const i -> ("[TODO: Integer]"++)
  ChrCon c -> ('\'':) . (c:) . ('\'':)
  StrCon s -> ('"':) . (s++) . ('"':)

showPat = \case
  PatLit e -> showExtra e
  PatVar s mp -> (s++) . maybe id ((('@':) .) . showPat) mp
  PatCon s ps -> (s++) . ("TODO"++)

showAst prec t = case t of
  E e -> showExtra e
  V s -> showVar s
  A (E (Basic f)) (E (Basic c)) | f == comEnum "F" -> ("FFI_"++) . showInt c
  A x y -> showParen prec $ showAst False x . (' ':) . showAst True y
  L s t -> par $ ('\\':) . (s++) . (" -> "++) . showAst prec t
  Pa vsts -> ('\\':) . par (foldr (.) id $ intersperse (';':) $ map (\(vs, t) -> foldr (.) id (intersperse (' ':) $ map (par . showPat) vs) . (" -> "++) . showAst False t) vsts)
  Ca x as -> ("case "++) . showAst False x . ("of {"++) . foldr (.) id (intersperse (',':) $ map (\(p, a) -> showPat p . (" -> "++) . showAst False a) as)
  Proof p -> ("{Proof "++) . showPred p . ("}"++)

showTree prec t = case t of
  LfVar s -> showVar s
  Lf extra -> showExtra extra
  Nd (Lf (Basic f)) (Lf (Basic c)) | f == comEnum "F" -> ("FFI_"++) . showInt c
  Nd x y -> showParen prec $ showTree False x . (' ':) . showTree True y
disasm (s, t) = (s++) . (" = "++) . showTree False t . (";\n"++)

dumpCombs s = case untangle s of
  Left err -> err
  Right ((_, lambs), _) -> foldr ($) [] $ map disasm $ optiComb lambs

dumpLambs s = case untangle s of
  Left err -> err
  Right ((_, lambs), _) -> foldr ($) [] $
    (\(s, t) -> (s++) . (" = "++) . showAst False t . ('\n':)) <$> lambs

showQual (Qual ps t) = foldr (.) id (map showPred ps) . showType t

dumpTypes s = case untangle s of
  Left err -> err
  Right ((typed, _), _) -> ($ "") $ foldr (.) id $
    map (\(s, q) -> (s++) . (" :: "++) . showQual q . ('\n':)) $ toAscList typed

-- Hash consing.
instance (Eq a, Eq b) => Eq (Either a b) where
  (Left a) == (Left b) = a == b
  (Right a) == (Right b) = a == b
  _ == _ = False
instance (Ord a, Ord b) => Ord (Either a b) where
  x <= y = case x of
    Left a -> case y of
      Left b -> a <= b
      Right _ -> True
    Right a -> case y of
      Left _ -> False
      Right b -> a <= b

instance (Eq a, Eq b) => Eq (a, b) where
  (a1, b1) == (a2, b2) = a1 == a2 && b1 == b2
instance (Ord a, Ord b) => Ord (a, b) where
  (a1, b1) <= (a2, b2) = a1 <= a2 && (not (a2 <= a1) || b1 <= b2)

memget k@(a, b) = get >>= \(tab, (hp, f)) -> Right <$> case mlookup k tab of
  Nothing -> put (insert k hp tab, (hp + 2, f . (a:) . (b:))) >> pure hp
  Just v -> pure v

enc t = case t of
  Lf n -> case n of
    Basic c -> pure $ Right c
    Const (Integer xsgn xs) ->
      enc $ Nd (Nd (lf "V") (lf "K")) $ foldr (\h t -> Nd (Nd (lf "CONS") $ Nd (lf "NUM") (Lf $ Basic $ intFromWord h)) t) (lf "K") xs
    ChrCon c -> memget (Right $ comEnum "NUM", Right $ ord c)
    StrCon s -> enc $ foldr (\h t -> Nd (Nd (lf "CONS") (Lf $ ChrCon h)) t) (lf "K") s
  LfVar s -> pure $ Left s
  Nd x y -> enc x >>= \hx -> enc y >>= \hy -> memget (hx, hy)

asm combs = foldM
  (\symtab (s, t) -> either (const symtab) (flip (insert s) symtab) <$> enc t)
  Tip combs

hashcons combs = fpair (runState (asm combs) (Tip, (128, id)))
  \symtab (_, (_, f)) -> (symtab,) $ either (maybe undefined id . (`mlookup` symtab)) id <$> f []

-- Code generation.
-- Fragile. We search for the above comment and replace the code below to
-- build the web demo.
customMods = id

libc = ([r|#include<stdio.h>
int env_argc;
int getargcount() { return env_argc; }
char **env_argv;
char getargchar(int n, int k) { char *tmp = env_argv[n]; return tmp[k]; }
char *buf;
char *bufp;
FILE *fp;
void reset_buffer() { bufp = buf; }
void put_buffer(int n) { bufp[0] = n; bufp = bufp + 1; }
void stdin_load_buffer() { fp = fopen(buf, "r"); }
int getchar_fp(void) { int n = fgetc(fp); if (n < 0) fclose(fp); return n; }
void putchar_cast(char c) { fputc(c,stdout); }
void *malloc(unsigned long);
|]++)

argList t = case t of
  TC s -> [TC s]
  TV s -> [TV s]
  TAp (TC "IO") (TC u) -> [TC u]
  TAp (TAp (TC "->") x) y -> x : argList y

cTypeName (TC "()") = "void"
cTypeName (TC "Int") = "int"
cTypeName (TC "Char") = "char"

ffiDeclare (name, t) = let tys = argList t in concat
  [cTypeName $ last tys, " ", name, "(", intercalate "," $ cTypeName <$> init tys, ");\n"]

ffiArgs n t = case t of
  TC s -> ("", ((True, s), n))
  TAp (TC "IO") (TC u) -> ("", ((False, u), n))
  TAp (TAp (TC "->") x) y -> first (((if 3 <= n then ", " else "") ++ "num(" ++ showInt n ")") ++) $ ffiArgs (n + 1) y

ffiDefine n ffis = case ffis of
  [] -> id
  (name, t):xt -> fpair (ffiArgs 2 t) \args ((isPure, ret), count) -> let
    lazyn = ("lazy2(" ++) . showInt (if isPure then count - 1 else count + 1) . (", " ++)
    aa tgt = "app(arg(" ++ showInt (count + 1) "), " ++ tgt ++ "), arg(" ++ showInt count ")"
    longDistanceCall = name ++ "(" ++ args ++ ")"
    in ("else if (n == " ++) . showInt n . (") { " ++) . if ret == "()"
      then (longDistanceCall ++) . (';':) . lazyn . (((if isPure then "_I, _K" else aa "_K") ++ "); }\n") ++) . ffiDefine (n - 1) xt
      else lazyn . (((if isPure then "_NUM, " ++ longDistanceCall else aa $ "app(_NUM, " ++ longDistanceCall ++ ")") ++ "); }\n") ++) . ffiDefine (n - 1) xt

genMain n = "int main(int argc,char**argv){env_argc=argc;env_argv=argv;init_prog();rts_reduce(" ++ showInt n ");return 0;}\n"

progLine p r = "  prog[" ++ showInt (fst p) "] = " ++ showInt (snd p) (";\n"++r);
progBody mem = foldr (.) id (map progLine (zipWith (,) [0..] mem ));

data Target = Host | Wasm

targetFuns Host = libc
targetFuns Wasm = ([r|
extern u __heap_base;
void* malloc(unsigned long n) {
  static u bump = (u) &__heap_base;
  return (void *) ((bump += n) - n);
}
|]++)

enumTop Host = ("// CONSTANT TOP 16777216\n#define TOP 16777216\n"++)
enumTop Wasm = ("enum{TOP=1<<22};"++)
enumComs = ("// CONSTANT _UNDEFINED 0\n#define _UNDEFINED 0\n"++)
  . foldr (.) id (map (\(s, _) -> ("// CONSTANT _"++) . (s++) . (" "++) . (showInt (comEnum s))
    . ("\n#define _"++) . (s++) . (" "++) . (showInt (comEnum s)) . ('\n':)) comdefs)

compile tgt s = either id id do
  ((typed, lambs), (ffis, exs)) <- untangle s
  let
    (tab, mem) = hashcons $ optiComb lambs
    getIOType (Qual [] (TAp (TC "IO") t)) = Right t
    getIOType q = Left $ "main : " ++ showQual q ""
    mustType s = case mlookup s typed of
      Just (Qual [] t) -> t
      _ -> error "TODO: report bad exports"
  maybe (Right undefined) getIOType $ mlookup "main" typed
  pure
    $ enumTop tgt
    . enumComs
    . ("\nvoid *malloc(unsigned long);\n" ++)
    . ("\nunsigned *prog;\nvoid init_prog() \n{\n" ++)
    . ("  prog = malloc(" ++) . showInt (length mem) . ("* sizeof(unsigned));\n"++)
    . progBody mem
    . ("}\nunsigned prog_size="++) . showInt (length mem) . (";\n"++)
    . targetFuns tgt
    . preamble
    . (concatMap ffiDeclare ffis ++)
    . foreignFun ffis
    . runFun
    . rtsInit tgt
    . rtsReduce
    . ("#define EXPORT(f, sym) void f() asm(sym) __attribute__((visibility(\"default\")));\n"++)
    . foldr (.) id (zipWith (\p n -> ("EXPORT(f"++) . showInt n . (", \""++) . (fst p++) . ("\")\n"++)
      . genExport (arrCount $ mustType $ snd p) n) exs [0..])
    $ maybe "" genMain (mlookup "main" tab)

genExport m n = ("void f"++) . showInt n . ("("++)
  . foldr (.) id (intersperse (',':) xs)
  . ("){rts_reduce("++)
  . foldl (\s x -> ("app("++) . s . (",app(_NUM,"++) . x . ("))"++)) rt xs
  . (");}\n"++)
  where
  xs = map ((('x':) .) . showInt) [0..m - 1]
  rt = ("root["++) . showInt n . ("]"++)

arrCount = \case
  TAp (TAp (TC "->") _) y -> 1 + arrCount y
  _ -> 0

-- Main VM loop.
comdefsrc = [r|
F x = "foreign(arg(1));"
Y x = x "sp[1]"
Q x y z = z(y x)
QQ f a b c d = d(c(b(a(f))))
S x y z = x z(y z)
B x y z = x (y z)
C x y z = x z y
R x y z = y z x
V x y z = z x y
T x y = y x
K x y = "_I" x
I x = "sp[1] = arg(1); sp = sp + CELL_SIZE;"
CONS x y z w = w x y
NUM x y = y "sp[1]"
DADD x y = "lazyDub(dub(1,2) + dub(3,4));"
DSUB x y = "lazyDub(dub(1,2) - dub(3,4));"
DMUL x y = "lazyDub(dub(1,2) * dub(3,4));"
DDIV x y = "lazyDub(dub(1,2) / dub(3,4));"
DMOD x y = "lazyDub(dub(1,2) % dub(3,4));"
ADD x y = "_NUM" "num(1) + num(2)"
SUB x y = "_NUM" "num(1) - num(2)"
MUL x y = "_NUM" "num(1) * num(2)"
QUOT x y = "_NUM" "num(1) / num(2)"
REM x y = "_NUM" "num(1) % num(2)"
DIV x y = "_NUM" "div(num(1), num(2))"
MOD x y = "_NUM" "mod(num(1), num(2))"
EQ x y = "if (num(1) == num(2)) lazy2(2, _I, _K); else lazy2(2, _K, _I);"
LE x y = "if (num(1) <= num(2)) lazy2(2, _I, _K); else lazy2(2, _K, _I);"
U_DIV x y = "_NUM" "num(1) / num(2)"
U_MOD x y = "_NUM" "num(1) % num(2)"
U_LE x y = "if (num(1) <= num(2)) lazy2(2, _I, _K); else lazy2(2, _K, _I);"
REF x y = y "sp[1]"
READREF x y z = z "num(1)" y
WRITEREF x y z w = "mem[arg(2) + 1] = arg(1); lazy3(4,arg(4),_K,arg(3));"
END = "return;"
|]
comb = (,) <$> wantConId <*> ((,) <$> many wantVarId <*> (res "=" *> combExpr))
combExpr = foldl1 A <$> some
  (V <$> wantVarId <|> E . StrCon <$> wantString <|> paren combExpr)
comdefs = case lex posLexemes $ LexState comdefsrc (1, 1) of
  Left e -> error e
  Right (xs, _) -> case parse (braceSep comb) $ ParseState (offside xs) Tip of
    Left e -> error e
    Right (cs, _) -> cs
comEnum s = maybe (error s) id $ lookup s $ zip (fst <$> comdefs) [1..]
comName i = maybe undefined id $ lookup i $ zip [1..] (fst <$> comdefs)

preamble = ([r|
// CONSTANT FALSE 0
#define FALSE 0
// CONSTANT TRUE 1
#define TRUE 1

// CONSTANT FORWARD 127
#define FORWARD 127
// CONSTANT REDUCING 126
#define REDUCING 126

//CONSTANT CELL_SIZE sizeof(unsigned)
#define CELL_SIZE 1

unsigned* mem;
unsigned* altmem;
unsigned* sp;
unsigned* spTop;
unsigned hp;

unsigned ready = 0;

unsigned isAddr(unsigned n)
{
	return n >= 128;
}

unsigned evac(unsigned n)
{
	if(!isAddr(n))
	{
		return n;
	}

	unsigned x = mem[n];

	while(isAddr(x) && mem[x] == _T)
	{
		mem[n] = mem[n + 1];
		mem[n + 1] = mem[x + 1];
		x = mem[n];
	}

	if(isAddr(x) && mem[x] == 'K')
	{
		mem[n + 1] = mem[x + 1];
		x = mem[n] = 'I';
	}

	unsigned y = mem[n + 1];

	if(FORWARD == x)
	{
		return y;
	}
	else if(REDUCING == x)
	{
		mem[n] = FORWARD;
		mem[n + 1] = hp;
		hp = hp + 2;
		return mem[n + 1];
	}
	else if(_I == x)
	{
		mem[n] = REDUCING;
		y = evac(y);

		if(mem[n] == FORWARD)
		{
			altmem[mem[n + 1]] = 'I';
			altmem[mem[n + 1] + 1] = y;
		}
		else
		{
			mem[n] = FORWARD;
			mem[n + 1] = y;
		}

		return mem[n + 1];
	}

	unsigned z = hp;
	hp = hp + 2;
	mem[n] = FORWARD;
	mem[n + 1] = z;
	altmem[z] = x;
	altmem[z + 1] = y;
	return z;
}

void gc()
{
	/* Reset the heap pointer */
	hp = 128;
	unsigned di = hp;
	/* Set the stack pointer to point to the top of altmem */
	sp = altmem + ((TOP - 1) * CELL_SIZE);

	unsigned i;

	sp[0] = evac(spTop[0]);

	unsigned x;
	while(di < hp)
	{
		altmem[di] = evac(altmem[di]);
		x = altmem[di];
		di = di + 1;

		if(x != _F && x != _NUM)
		{
			altmem[di] = evac(altmem[di]);
		}

		di = di + 1;
	}

	spTop = sp;
	/* Swap the addresses of mem and altmem */
	unsigned *tmp = mem;
	mem = altmem;
	altmem = tmp;
}

unsigned app(unsigned f, unsigned x)
{
	mem[hp] = f;
	mem[hp + 1] = x;
	hp = hp + 2;
	return hp - 2;
}

unsigned arg(unsigned n)
{
	return mem[sp [n] + 1];
}

int num(unsigned n)
{
	return mem[arg(n) + 1];
}

unsigned lazy2(unsigned height, unsigned f, unsigned x)
{
	unsigned* p;
	p = mem + (sp[height] * CELL_SIZE);
	p[0] = f;
	p[1] = x;
	sp = sp + ((height - 1) * CELL_SIZE);
	sp[0] = f;
	return 0;
}

unsigned lazy3(unsigned height, unsigned x1, unsigned x2, unsigned x3)
{
	unsigned* p;
	p = mem + (sp[height] * CELL_SIZE);
	p[0] = app(x1, x2);
	p[1] = x3;
	sp[height - 1] = p[0];
	sp = sp + ((height - 2) * CELL_SIZE);
	sp[0] = x1;
	return 0;
}

void lazyDub(unsigned n) { lazy3(4, _V, app(_NUM, n), app(_NUM, 0)); }
unsigned dub(unsigned lo, unsigned hi) { return num(lo); }
|]++)

runFun = ([r|
int div(int a, int b) { return a/b; }
int mod(int a, int b) { return a%b; }
void run() {
  unsigned x;
  while(TRUE)
  {
    if (mem + (hp * CELL_SIZE) > sp - (8 * CELL_SIZE))
    {
      gc();
    }
    x = sp[0];
    if (isAddr(x))
    {
      sp = sp - CELL_SIZE;
      sp[0] = mem[x];
    }
|]++)
  . foldr (.) id (genComb <$> comdefs)
  . ([r|
  }
}
|]++)

rtsInit tgt = ([r|
void rts_init() {|]++) . (case tgt of
  Host -> ("\n  fp = stdin;\n  buf = malloc(1024 * sizeof(char));\n  bufp = buf;\n"++)
  _ -> id) . ([r|
  mem = malloc(TOP * sizeof(unsigned)); altmem = malloc(TOP * sizeof(unsigned));
  hp = 128;
  unsigned i;
  for (i = 0; i < prog_size; i = i + 1)
  {
    mem[hp] = prog[i];
    hp = hp + 1;
  }
  spTop = mem + ((TOP - 1) * CELL_SIZE);
}
|]++)

rtsReduce = ([r|
void rts_reduce(unsigned n) {
  if (!ready)
  {
    ready = 1;
    rts_init();
  }
  sp = spTop;
  spTop[0] = app(app(n, _UNDEFINED), _END);
  run();
}
|]++)

genArg m a = case a of
  V s -> ("arg("++) . (maybe undefined showInt $ lookup s m) . (')':)
  E (StrCon s) -> (s++)
  A x y -> ("app("++) . genArg m x . (',':) . genArg m y . (')':)
genArgs m as = foldl1 (.) $ map (\a -> (","++) . genArg m a) as
genComb (s, (args, body)) = let
  argc = ('(':) . showInt (length args)
  m = zip args [1..]
  in ("  else if (x == _"++) . (s++) . (')':) . (case body of
    A (A x y) z -> (" { lazy3"++) . argc . genArgs m [x, y, z] . ("); }"++)
    A x y -> (" { lazy2"++) . argc . genArgs m [x, y] . ("); }"++)
    E (StrCon s) -> (" { "++) . (s++) . (" }"++)
  ) . ("\n"++)

declDemo = ([r|#define IMPORT(m,n) __attribute__((import_module(m))) __attribute__((import_name(n)));
void putchar(int) IMPORT("env", "putchar");
int getchar(void) IMPORT("env", "getchar");
int eof(void) IMPORT("env", "eof");
enum {
  ROOT_BASE = 1<<9,  // 0-terminated array of exported functions
  // HEAP_BASE - 4: program size
  HEAP_BASE = (1<<20) - 128 * sizeof(u),  // program
  TOP = 1<<22
};
static u *root = (u*) ROOT_BASE;
|]++)

rtsInitDemo = ([r|
static inline void rts_init() {
  mem = (u*) HEAP_BASE; altmem = (u*) (HEAP_BASE + (TOP - 128) * sizeof(u));
  hp = 128 + mem[127];
  spTop = mem + TOP - 1;
}
|]++)

foreignFun ffis =
    ("void foreign(unsigned n) {\nif (FALSE) {}\n" ++)
  . ffiDefine (length ffis - 1) ffis
  . ("}\n" ++)

demoFFIs =
  [ ("putchar", arr (TC "Char") $ TAp (TC "IO") (TC "()"))
  , ("getchar", TAp (TC "IO") (TC "Char"))
  , ("eof", TAp (TC "IO") (TC "Int"))
  ]

main = getArgs >>= \case
  "coms":_ -> putStr $ ("comlist = [\""++)
    . foldr (.) id (intersperse ("\",\""++) $ (++) . fst <$> comdefs)
    $ "\"]\n"
  "blah":_ -> putStr $ enumComs . declDemo . preamble . foreignFun demoFFIs . runFun . rtsInitDemo . rtsReduce $ [r|
void fun(void) asm("fun") __attribute__((visibility("default")));
void fun(void) { rts_reduce(*((u*)512)); }
|]
  "comb":_ -> interactCPP dumpCombs
  "lamb":_ -> interactCPP dumpLambs
  "type":_ -> interactCPP dumpTypes
  "wasm":_ -> interactCPP $ compile Wasm
  _ -> interactCPP $ compile Host
  where
  getArg' k n = getArgChar n k >>= \c -> if ord c == 0 then pure [] else (c:) <$> getArg' (k + 1) n
  getArgs = getArgCount >>= \n -> mapM (getArg' 0) [1..n - 1]

-- Include directives.
interactCPP f = do
  s <- getContents
  case lex cppLexer $ LexState s (0,0) of
    Left e -> putStr $ "CPP error: " ++ e
    Right (r, _) -> cpp r >>= putStr . f

data CPP = CPPPass (String -> String) | CPPInclude String
cppLexer = many $ include <|> (CPPPass . foldr (.) ('\n':) . map (:) <$> many (sat (/= '\n')) <* char '\n')
include = (foldr (*>) (pure ()) $ map char "#include") *> many (sat isSpace) *>
  (CPPInclude <$> tokStr) <* char '\n'
cpp cpps = foldr ($) "" <$> mapM go cpps where
  go (CPPPass f) = pure f
  go (CPPInclude s) = do
    resetBuffer
    mapM_ (putBuffer . ord) s
    putBuffer 0
    stdinLoadBuffer
    getContentsS
getContentsS = getChar >>= \n -> if 0 <= n then ((chr n:) .) <$> getContentsS else pure id
