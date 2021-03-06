module Hbacklight where
import Prelude hiding (max, readFile)
import Control.Monad (when, foldM)
import Control.Applicative (optional)
import Options.Applicative (Parser, execParser, info, helper, fullDesc, progDesc, header, metavar, long, short, strOption, help, switch)
import Data.Semigroup ((<>))
import System.Directory (doesFileExist, doesDirectoryExist)
import Text.Read (readMaybe)
import Text.PrettyPrint.Boxes (Box(..), text, vcat, left, right, printBox, (<+>))
import System.IO.Strict (readFile)
import System.Posix.IO (openFd, fdWrite, OpenMode(..), defaultFileFlags)
import Control.Monad.Trans.Except

devicePath :: String
devicePath = "/sys/class/backlight/"


deviceSub :: [(String, Device)]
deviceSub =
    [ ("power"      , "bl_power")
    , ("brightness" , "brightness")
    , ("actual"     , "actual_brightness")
    , ("max"        , "max_brightness")
    , ("type"       , "type") ]


lookupJust :: (Eq a) => a -> [(a, b)] -> b
lookupJust x xs = case x `lookup` xs of
    Nothing  -> error "key not present"
    Just r   -> r


data Interface = Backlight
    { power      :: Integer
    , brightness :: Integer
    , actual     :: Integer
    , max        :: Integer
    , type'      :: String
    , name       :: String
    , mode       :: Mode }
    deriving (Show)


type Device = String


data Opts = Opts
    { id'     :: String
    , verbose :: Bool
    , delta   :: Maybe String }


data Mode = Plus Integer | Minus Integer | Percent Integer | Set Integer | NoOp deriving (Show)


toMode :: String -> Either String Mode
toMode s = case f s of
    Nothing -> Left $ "could not parse delta: " <> s
    Just m  -> Right m
    where
        f ('+':xs) = Plus    <$> readMaybe xs
        f ('-':xs) = Minus   <$> readMaybe xs
        f ('%':xs) = Percent <$> readMaybe xs
        f ('~':xs) = Set     <$> readMaybe xs
        f xs       = Set     <$> readMaybe xs


opts :: Parser Opts
opts = Opts
    <$> strOption
        ( long "id"
        <> short 'i'
        <> metavar "TARGET"
        <> help "Identifier of backlight device" )
    <*> switch
        (long "verbose"
        <> short 'v'
        <> help "informative of backlight device state"
        )
    <*> (optional . strOption)
        ( long "delta"
        <> short 'd'
        <> metavar "[+,-,%,~]AMOUNT"
        <> help "Modify the backlight value, ~ sets the value to AMOUNT, else shift is relative. Defaults to ~" )


parseDevicePath :: String -> String -> String -> String -> String -> String -> Mode -> Either String Interface
parseDevicePath a1 a2 a3 a4 a5 a6 m = case r of
  Nothing -> Left "err: cannot stat device properties"
  Just x  -> Right x
  where
      r = Backlight
        <$> readMaybe a1
        <*> readMaybe a2
        <*> readMaybe a3
        <*> readMaybe a4
        <*> pure a5
        <*> pure a6
        <*> pure m


parseDevice :: Device -> Mode -> IO (Either String Interface)
parseDevice d m = do
    let parent   = devicePath <> d <> "/"
    let paths = (parent <>) . snd <$> deviceSub
    valid <- (&&) <$> doesDirectoryExist parent <*> foldM
        (\acc x -> (&&) <$> doesFileExist x <*> pure acc)
        True
        paths
    if valid
        then do
            (a1:a2:a3:a4:a5:_) <- traverse (fmap (filter (/= '\n')) . readFile) paths
            return $ parseDevicePath a1 a2 a3 a4 a5 d m
        else return . Left $ "err: cannot locate device: " <> d


dim :: Interface -> IO ()
dim (Backlight _ _ _ _ _ _ NoOp) = return ()
dim i = case mode i of
    Plus x    -> setV $ lvl + x
    Minus x   -> setV $ lvl - x
    Percent x -> let
        p    = (fromIntegral x / 100)
        m    = fromIntegral . max $ i
        in setV . round $ p * m
    Set x     -> setV x
    NoOp      -> return ()
    where
        path = devicePath <> name i <> "/" <> lookupJust "brightness" deviceSub
        fd   = openFd
            path
            WriteOnly
            Nothing
            defaultFileFlags
        lvl     = brightness i
        setV v  = fd >>= \handle -> handle `fdWrite` show v >> return ()


idL :: Int
idL = 16


table :: Interface -> Box
table i = lv <+> rv where
    lv = vcat left $ text <$> "device" : map snd deviceSub
    rv = vcat right $ text <$>
        [ take idL $ name i
        , show . power $ i
        , show . brightness $ i
        , show . actual $ i
        , show . max $ i
        , type' i
        ]


run :: Opts -> IO ()
run o = do
    let m = maybe (Right NoOp)  toMode  $ delta o
    interface <- runExceptT $ ExceptT . parseDevice (id' o) =<< except m
    case interface of
        Left e -> putStrLn e
        Right i -> do
            when (verbose o) $ printBox . table $ i
            dim i


main :: IO ()
main = run =<< execParser cmd where
    cmd = info (helper <*> opts )
        ( fullDesc
        <> progDesc "Adjust backlight device"
        <> header "hbacklight - backlight manager" )
