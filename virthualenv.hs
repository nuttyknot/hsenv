{-# LANGUAGE GeneralizedNewtypeDeriving
  #-}
import System.Environment (getEnv, getProgName, getArgs, getEnvironment)
import System.IO (stderr, hPutStrLn, hGetContents, hPutStr, Handle)
import System.IO.Error (isDoesNotExistError)
import System.Exit (exitFailure, ExitCode(..))
import System.Process (readProcess, runInteractiveProcess, waitForProcess)
import System.Cmd (rawSystem)
import System.Directory (getCurrentDirectory, createDirectory, executable, getPermissions, setPermissions)
import System.FilePath ((</>), splitPath)
import Data.List (isPrefixOf, intercalate)
import Control.Monad
import Data.Char (isSpace)
import Distribution.Compat.ReadP
import Distribution.Package
import Distribution.Version
import Distribution.Text
import Data.Maybe(catMaybes)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT, MonadReader, runReaderT, asks)
import Control.Monad.State (StateT, MonadState, evalStateT, modify, gets)

import Paths_virthualenv (getDataFileName)

data Options = Options { verbose :: Bool
                       , vheName :: String
                       }

data MyState = MyState { logDepth :: Integer
                       }

newtype MyMonad a = MyMonad { unMyMonad :: StateT MyState (ReaderT Options IO) a }
    deriving (Monad, MonadReader Options, MonadIO, MonadState MyState)

runMyMonad :: MyMonad a -> Options -> IO a
runMyMonad m = runReaderT (evalStateT (unMyMonad m) (MyState 0))

debugBlock :: MyMonad a -> MyMonad a
debugBlock m = do
  modify (\s -> s{logDepth = logDepth s + 2})
  result <- m
  modify (\s -> s{logDepth = logDepth s - 2})
  return result

debug :: String -> MyMonad ()
debug s = do
  flag <- asks verbose
  if flag then do
      depth <- gets logDepth
      liftIO $ putStrLn $ replicate (fromInteger depth) ' ' ++ s
   else
      return ()

-- run a process in a Virtual Haskell Environment
-- returns process output and exit status
envProcess :: String -> [String] -> Maybe Handle -> MyMonad (String, ExitCode)
envProcess prog args input = do
  env <- getVirtualEnvironment
  (inp, out, _, pid) <- liftIO $ runInteractiveProcess prog args Nothing (Just env)
  case input of
    Nothing     -> return ()
    Just handle -> liftIO $ hGetContents handle >>= hPutStr inp
  result   <- liftIO $ hGetContents out
  exitCode <- liftIO $ waitForProcess pid
  return (result, exitCode)

data DirStructure = DirStructure { virthualEnv       :: FilePath
                                 , virthualEnvDir    :: FilePath
                                 , ghcPackagePath    :: FilePath
                                 , cabalDir          :: FilePath
                                 , cabalBinDir       :: FilePath
                                 , virthualEnvBinDir :: FilePath
                                 }

getEnvVar :: String -> IO (Maybe String)
getEnvVar var = Just `fmap` getEnv var `catch` noValueHandler
    where noValueHandler e | isDoesNotExistError e = return Nothing
                           | otherwise             = ioError e

-- check if any virtual env is already active
checkVHE :: IO Bool
checkVHE = do
    virthualEnvVar <- getEnvVar "VIRTHUALENV"
    case virthualEnvVar of
        Nothing   -> return False
        Just path -> do
            virthualEnvName <- getEnvVar "VIRTHUALENV_NAME"
            case virthualEnvName of
                Nothing -> do
                       hPutStrLn stderr $
                           "warning: VIRTHUALENV environment variable is defined"
                        ++ ", but no VIRHTUALENV_NAME environment variable defined."
                       putStrLn $ "There is already active Virtual Haskell Environment (at " ++ path ++ ")."
                Just name -> do
                    putStrLn $ "There is already active " ++ name ++ " Virtual Haskell Environment (at " ++ path ++ ")."
            return True

usage :: IO ()
usage = do
    name <- getProgName
    putStrLn $ "usage: " ++ name ++ " [FLAGS]"
    putStrLn ""
    putStrLn "Flags:"
    putStrLn "-h --help Show this help message"
    putStrLn "--verbose Print some debugging info"
    putStrLn "--name=NAME Use Name for name of Virthual Haskell Environment"
    putStrLn ""
    putStrLn "Creates Virtual Haskell Environment in the current directory."
    putStrLn "All files will be stored in the .virthualenv/ subdirectory."

parseArgs :: [String] -> IO (Maybe Options)
parseArgs args = do
  let (verbosityFlags, nonVerbosityFlags) = span (== "--verbose") args
      verbosity = not $ null verbosityFlags
      (nameFlags, nonNameFlags) = span ("--name=" `isPrefixOf`) nonVerbosityFlags
  name <- case nameFlags of
           nameFlag:_ -> return $ drop (length "--name=") nameFlag
           [] -> do
             cwd <- liftIO getCurrentDirectory
             let dirs = splitPath cwd
                 name = last dirs
             when verbosity $ putStrLn $ "Using current directory name as Virtual Haskell Environment name: " ++ name
             return name
  case nonNameFlags of
    [] -> return $ Just Options { verbose = verbosity
                               , vheName = name
                               }
    _ -> return Nothing

-- TODO: it should return IO (Maybe String)
-- TODO: it should walk the PATH elems, instead of using system's which util
which :: String -> IO String
which progName = do
  output <- readProcess "which" [progName] ""
  let result = init output -- skip final newline
  return result

prettyVersion :: Version -> String
prettyVersion (Version [] _) = ""
prettyVersion (Version numbers _) = intercalate "." $ map show numbers

prettyPkgInfo :: PackageIdentifier -> String
prettyPkgInfo (PackageIdentifier (PackageName name) (Version [] _)) = name
prettyPkgInfo (PackageIdentifier (PackageName name) version) =
  name ++ "-" ++ prettyVersion version

getDeps :: PackageIdentifier -> MyMonad [PackageIdentifier]
getDeps pkgInfo = do
  debug $ "Extracting dependencies of " ++ prettyPkgInfo pkgInfo
  x <- liftIO $ readProcess "ghc-pkg" ["field", prettyPkgInfo pkgInfo, "depends"] ""
  let depStrings = tail $ words x
  mapM parsePackageName depStrings

-- transplant a package from simple name (e.g. base)
-- tries to guess the version
transplantPackage :: String -> MyMonad ()
transplantPackage package = do
  debug $ "Copying package " ++ package ++ " to Virtual Haskell Environment."
  debugBlock $ do
    debug $ "Choosing package with highest version number."
    out <- debugBlock $ liftIO $ readProcess "ghc-pkg" ["field", package, "version"] ""
    -- example output:
    -- version: 1.1.4
    -- version: 1.2.0.3
    let versionStrings = map (!!1) $ map words $ lines out
        versions = catMaybes $ map (\s -> parseCheck parse s "version") versionStrings
    debugBlock $ debug $ "Found: " ++ unwords (map prettyVersion versions)
    let version = maximum versions
    debugBlock $ debug $ "Using version: " ++ prettyVersion version
    let pkgInfo = PackageIdentifier (PackageName package) version
    transplantPkg pkgInfo

-- returns environment dictionary used in Virtual Haskell Environment
-- it's inherited from the current process, but variable
-- GHC_PACKAGE_PATH is altered.
getVirtualEnvironment :: MyMonad [(String, String)]
getVirtualEnvironment = do
  env <- liftIO getEnvironment
  dirStructure <- vheDirStructure
  return $ ("GHC_PACKAGE_PATH", ghcPackagePath dirStructure) : filter (\(k,_) -> k /= "GHC_PACKAGE_PATH") env

-- check if this package is already installed in Virtual Haskell Environment
checkIfInstalled :: PackageIdentifier -> MyMonad Bool
checkIfInstalled pkgInfo = do
  let package = prettyPkgInfo pkgInfo
  debug $ "Checking if " ++ package ++ " is already installed."
  (_, exitCode) <- debugBlock $ envProcess "ghc-pkg" ["describe", package] Nothing
  debugBlock $ case exitCode of
                 ExitSuccess -> do
                   debug "It is."
                   return True
                 ExitFailure _ -> do
                   debug "It's not."
                   return False

transplantPkg :: PackageIdentifier -> MyMonad ()
transplantPkg pkgInfo = do
  debug $ "Copying package " ++ prettyPkgInfo pkgInfo ++ " to Virtual Haskell Environment."
  debugBlock $ do
    flag <- checkIfInstalled pkgInfo
    if flag then
        return ()
     else do
      deps <- getDeps pkgInfo
      debug $ "Found: " ++ unwords (map prettyPkgInfo deps)
      mapM_ transplantPkg deps
      movePackage pkgInfo

parseCheck :: Monad m => ReadP a a -> String -> String -> m a
parseCheck parser str what =
  case [ x | (x,ys) <- readP_to_S parser str, all isSpace ys ] of
    [x] -> return x
    _ -> error ("cannot parse \'" ++ str ++ "\' as a " ++ what)

parsePackageName :: Monad m => String -> m PackageIdentifier
parsePackageName str | "builtin_" `isPrefixOf` str =
                         let name = drop (length "builtin_") str
                         in return $ PackageIdentifier (PackageName name) $ Version [] []
                     | otherwise = parseCheck parse str "package identifier"

-- copy single package that already has all deps satisfied
movePackage :: PackageIdentifier -> MyMonad ()
movePackage pkgInfo = do
  let package = prettyPkgInfo pkgInfo
  debug $ "Moving package " ++ prettyPkgInfo pkgInfo ++ " to Virtual Haskell Environment."
  (_, out, _, pid) <-
      liftIO $ runInteractiveProcess "ghc-pkg" ["describe", package] Nothing Nothing
  _ <- envProcess "ghc-pkg" ["register", "-"] (Just out)
  _ <- liftIO $ waitForProcess pid
  return ()

subst :: (String, String) -> String -> String
subst _ [] = []
subst (from, to) input@(x:xs) | from `isPrefixOf` input = to ++ subst (from, to) (drop (length from) input)
                              | otherwise = x:subst (from, to) xs

sed :: [(String, String)] -> FilePath -> FilePath -> IO ()
sed substs inFile outFile = do
  inp <- readFile inFile
  let out = foldr subst inp substs
  writeFile outFile out

makeExecutable :: FilePath -> IO ()
makeExecutable f = do
  p <- getPermissions f
  setPermissions f (p {executable = True})

cabalUpdate :: MyMonad ()
cabalUpdate = do
  env <- liftIO getEnvironment
  cabalConfig <- cabalConfigLocation
  dirStructure <- vheDirStructure
  let env' = ("GHC_PACKAGE_PATH", ghcPackagePath dirStructure) : filter (\(k,_) -> k /= "GHC_PACKAGE_PATH") env
  liftIO $ putStrLn "Updating cabal package database inside Virtual Haskell Environment."
  (_, _, _, pid) <-
      liftIO $ runInteractiveProcess "cabal"
                            ["--config-file=" ++ cabalConfig, "update"]
                            Nothing
                            (Just env')
  _ <- liftIO $ waitForProcess pid
  return ()

-- returns record containing paths to all important directories
-- inside virtual environment dir structure
vheDirStructure :: MyMonad DirStructure
vheDirStructure = do
  cwd <- liftIO getCurrentDirectory
  let virthualEnvLocation    = cwd
      virthualEnvDirLocation = virthualEnvLocation </> ".virthualenv"
      cabalDirLocation       = virthualEnvDirLocation </> "cabal"
  return DirStructure { virthualEnv       = virthualEnvLocation
                      , virthualEnvDir    = virthualEnvDirLocation
                      , ghcPackagePath    = virthualEnvDirLocation </> "ghc_pkg_db"
                      , cabalDir          = cabalDirLocation
                      , cabalBinDir       = cabalDirLocation </> "bin"
                      , virthualEnvBinDir = virthualEnvDirLocation </> "bin"
                      }

-- returns location of cabal's config file inside virtual environment dir structure
cabalConfigLocation :: MyMonad FilePath
cabalConfigLocation = do
  dirStructure <- vheDirStructure
  return $ cabalDir dirStructure </> "config"

-- install cabal wrapper (in bin/ directory) inside virtual environment dir structure
installCabalWrapper :: MyMonad ()
installCabalWrapper = do
  cabalConfig      <- cabalConfigLocation
  cabalWrapperSkel <- liftIO $ getDataFileName "cabal"
  origCabalBinary  <- liftIO $ which "cabal"
  dirStructure     <- vheDirStructure
  let cabalWrapper = virthualEnvBinDir dirStructure </> "cabal"
  liftIO $ putStrLn $ concat [ "Installing cabal wrapper using "
                             , origCabalBinary
                             , " and "
                             , cabalConfig
                             , " at "
                             , cabalWrapper
                             ]
  liftIO $ sed [ ("<ORIG_CABAL_BINARY>", origCabalBinary)
               , ("<CABAL_CONFIG>", cabalConfig)
               ] cabalWrapperSkel cabalWrapper
  liftIO $ makeExecutable cabalWrapper

-- install cabal wrapper (in bin/ directory) inside virtual environment dir structure
installActivateScript :: MyMonad ()
installActivateScript = do
  virthualEnvName <- asks vheName
  activateSkel    <- liftIO $ getDataFileName "activate"
  dirStructure    <- vheDirStructure
  let activateScript = virthualEnvBinDir dirStructure </> "activate"
  liftIO $ putStrLn $ "Installing activate script at " ++ activateScript
  liftIO $ sed [ ("<VIRTHUALENV_NAME>", virthualEnvName)
               , ("<VIRTHUALENV>", virthualEnv dirStructure)
               , ("<GHC_PACKAGE_PATH>", ghcPackagePath dirStructure)
               , ("<VIRTHUALENV_BIN_DIR>", virthualEnvBinDir dirStructure)
               , ("<CABAL_BIN_DIR>", cabalBinDir dirStructure)
               ] activateSkel activateScript

installCabalConfig :: MyMonad ()
installCabalConfig = do
  cabalConfigSkel <- liftIO $ getDataFileName "cabal_config"
  cabalConfig     <- cabalConfigLocation
  dirStructure    <- vheDirStructure
  liftIO $ putStrLn $ "Installing cabal config at " ++ cabalConfig
  liftIO $ sed [ ("<GHC_PACKAGE_PATH>", ghcPackagePath dirStructure)
               , ("<CABAL_DIR>", cabalDir dirStructure)
               ] cabalConfigSkel cabalConfig

createDirStructure :: MyMonad ()
createDirStructure = do
  dirStructure <- vheDirStructure
  liftIO $ putStrLn "Creating Virtual Haskell directory structure"
  debugBlock $ do
    debug $ "virthualenv directory: " ++ virthualEnvDir dirStructure
    liftIO $ createDirectory $ virthualEnvDir dirStructure
    debug $ "cabal directory: " ++ cabalDir dirStructure
    liftIO $ createDirectory $ cabalDir dirStructure
    debug $ "virthualenv bin directory: " ++ virthualEnvBinDir dirStructure
    liftIO $ createDirectory $ virthualEnvBinDir dirStructure

initGhcDb :: MyMonad ()
initGhcDb = do
  dirStructure <- vheDirStructure
  liftIO $ putStrLn $ "Initializing GHC Package database at " ++ ghcPackagePath dirStructure
  _ <- liftIO $ rawSystem "ghc-pkg" ["init", ghcPackagePath dirStructure]
  return ()

copyBaseSystem :: MyMonad ()
copyBaseSystem = do
  liftIO $ putStrLn "Copying necessary packages from original GHC package database"
  debugBlock $ do
    transplantPackage "base"
    transplantPackage "Cabal"
    transplantPackage "haskell98"

main :: IO ()
main = do
    envActive <- checkVHE
    when envActive exitFailure

    args <- getArgs
    case args of
      ["--help"] -> usage
      ["-h"]     -> usage
      _          -> do
                opts <- parseArgs args
                case opts of
                  Nothing      -> usage >> exitFailure
                  Just options -> runMyMonad realMain options

realMain :: MyMonad ()
realMain = do
  createDirStructure
  initGhcDb
  copyBaseSystem
  installCabalConfig
  installActivateScript
  installCabalWrapper
  cabalUpdate