{-# LANGUAGE CPP, TypeSynonymInstances, FlexibleInstances, RecordWildCards,
             GeneralizedNewtypeDeriving, StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow 2004-2009.
--
-- Package management tool
--
-----------------------------------------------------------------------------

module Main (main) where

import Version ( version, targetOS, targetARCH )
import qualified GHC.PackageDb as GhcPkg
import qualified Distribution.Simple.PackageIndex as PackageIndex
import qualified Data.Graph as Graph
import qualified Distribution.ModuleName as ModuleName
import Distribution.ModuleName (ModuleName)
import Distribution.InstalledPackageInfo as Cabal
import Distribution.Compat.ReadP hiding (get)
import Distribution.ParseUtils
import Distribution.Package hiding (depends, installedPackageId)
import Distribution.Text
import Distribution.Version
import Distribution.Simple.Utils (fromUTF8, toUTF8)
import System.FilePath as FilePath
import qualified System.FilePath.Posix as FilePath.Posix
import System.Process
import System.Directory ( getAppUserDataDirectory, createDirectoryIfMissing,
                          getModificationTime )
import Text.Printf

import Prelude

import System.Console.GetOpt
import qualified Control.Exception as Exception
import Data.Maybe

import Data.Char ( isSpace, toLower )
import Data.Ord (comparing)
#if __GLASGOW_HASKELL__ < 709
import Control.Applicative (Applicative(..))
#endif
import Control.Monad
import System.Directory ( doesDirectoryExist, getDirectoryContents,
                          doesFileExist, renameFile, removeFile,
                          getCurrentDirectory )
import System.Exit ( exitWith, ExitCode(..) )
import System.Environment ( getArgs, getProgName, getEnv )
import System.IO
import System.IO.Error
import GHC.IO.Exception (IOErrorType(InappropriateType))
import Data.List
import Control.Concurrent

import qualified Data.ByteString.Char8 as BS

#if defined(mingw32_HOST_OS)
-- mingw32 needs these for getExecDir
import Foreign
import Foreign.C
#endif

#ifdef mingw32_HOST_OS
import GHC.ConsoleHandler
#else
import System.Posix hiding (fdToHandle)
#endif

#if defined(GLOB)
import qualified System.Info(os)
#endif

#if !defined(mingw32_HOST_OS) && !defined(BOOTSTRAPPING)
import System.Console.Terminfo as Terminfo
#endif

#ifdef mingw32_HOST_OS
# if defined(i386_HOST_ARCH)
#  define WINDOWS_CCONV stdcall
# elif defined(x86_64_HOST_ARCH)
#  define WINDOWS_CCONV ccall
# else
#  error Unknown mingw32 arch
# endif
#endif

-- -----------------------------------------------------------------------------
-- Entry point

main :: IO ()
main = do
  args <- getArgs

  case getOpt Permute flags args of
        (cli,nonopts,[]) ->
           runit Normal cli nonopts

-- -----------------------------------------------------------------------------
-- Command-line syntax

data Flag
  = FlagGlobal
  | FlagGlobalConfig FilePath
  deriving Eq

flags :: [OptDescr Flag]
flags = [
  Option [] ["global"] (NoArg FlagGlobal)
        "use the global package database",
  Option [] ["global-package-db"] (ReqArg FlagGlobalConfig "DIR")
        "location of the global package database"
  ]

data Verbosity = Silent | Normal | Verbose
    deriving (Show, Eq, Ord)

-- -----------------------------------------------------------------------------
-- Do the business

data Force = NoForce | ForceFiles | ForceAll | CannotForce
  deriving (Eq,Ord)

-- | Enum flag representing argument type
data AsPackageArg
    = AsIpid
    | AsPackageKey
    | AsDefault

-- | Represents how a package may be specified by a user on the command line.
data PackageArg
    -- | A package identifier foo-0.1; the version might be a glob.
    = Id PackageIdentifier
    -- | An installed package ID foo-0.1-HASH.  This is guaranteed to uniquely
    -- match a single entry in the package database.
    | IPId InstalledPackageId
    -- | A package key foo_HASH.  This is also guaranteed to uniquely match
    -- a single entry in the package database
    | PkgKey PackageKey
    -- | A glob against the package name.  The first string is the literal
    -- glob, the second is a function which returns @True@ if the the argument
    -- matches.
    | Substring String (String->Bool)

runit :: Verbosity -> [Flag] -> [String] -> IO ()
runit verbosity cli nonopts = do
  installSignalHandlers -- catch ^C and clean up
  prog <- getProgramName
  let
        force = NoForce
        as_arg = AsDefault
        auto_ghci_libs = False
        multi_instance = False
        expand_env_vars= False
        mexpand_pkgroot= Nothing
                
        splitFields fields = unfoldr splitComma (',':fields)
          where splitComma "" = Nothing
                splitComma fs = Just $ break (==',') (tail fs)

        -- | Parses a glob into a predicate which tests if a string matches
        -- the glob.  Returns Nothing if the string in question is not a glob.
        -- At the moment, we only support globs at the beginning and/or end of
        -- strings.  This function respects case sensitivity.
        --
        -- >>> fromJust (substringCheck "*") "anything"
        -- True
        --
        -- >>> fromJust (substringCheck "string") "string"
        -- True
        --
        -- >>> fromJust (substringCheck "*bar") "foobar"
        -- True
        --
        -- >>> fromJust (substringCheck "foo*") "foobar"
        -- True
        --
        -- >>> fromJust (substringCheck "*ooba*") "foobar"
        -- True
        --
        -- >>> fromJust (substringCheck "f*bar") "foobar"
        -- False
        substringCheck :: String -> Maybe (String -> Bool)
        substringCheck ""    = Nothing
        substringCheck "*"   = Just (const True)
        substringCheck [_]   = Nothing
        substringCheck (h:t) =
          case (h, init t, last t) of
            ('*',s,'*') -> Just (isInfixOf (f s) . f)
            ('*',_, _ ) -> Just (isSuffixOf (f t) . f)
            ( _ ,s,'*') -> Just (isPrefixOf (f (h:s)) . f)
            _           -> Nothing
          where f = id
#if defined(GLOB)
        glob x | System.Info.os=="mingw32" = do
          -- glob echoes its argument, after win32 filename globbing
          (_,o,_,_) <- runInteractiveCommand ("glob "++x)
          txt <- hGetContents o
          return (read txt)
        glob x | otherwise = return [x]
#endif
  --
  -- first, parse the command
  recache verbosity cli

parseCheck :: ReadP a a -> String -> String -> IO a
parseCheck parser str what =
  case [ x | (x,ys) <- readP_to_S parser str, all isSpace ys ] of
    [x] -> return x
    _ -> die ("cannot parse \'" ++ str ++ "\' as a " ++ what)

readGlobPkgId :: String -> IO PackageIdentifier
readGlobPkgId str = parseCheck parseGlobPackageId str "package identifier"

parseGlobPackageId :: ReadP r PackageIdentifier
parseGlobPackageId =
  parse
     +++
  (do n <- parse
      _ <- string "-*"
      return (PackageIdentifier{ pkgName = n, pkgVersion = globVersion }))

-- globVersion means "all versions"
globVersion :: Version
globVersion = Version [] ["*"]

-- -----------------------------------------------------------------------------
-- Package databases

-- Some commands operate on a single database:
--      register, unregister, expose, hide, trust, distrust
-- however these commands also check the union of the available databases
-- in order to check consistency.  For example, register will check that
-- dependencies exist before registering a package.
--
-- Some commands operate  on multiple databases, with overlapping semantics:
--      list, describe, field

data PackageDB 
  = PackageDB {
      location, locationAbsolute :: !FilePath,
      -- We need both possibly-relative and definately-absolute package
      -- db locations. This is because the relative location is used as
      -- an identifier for the db, so it is important we do not modify it.
      -- On the other hand we need the absolute path in a few places
      -- particularly in relation to the ${pkgroot} stuff.
      
      packages :: [InstalledPackageInfo]
    }

type PackageDBStack = [PackageDB]
        -- A stack of package databases.  Convention: head is the topmost
        -- in the stack.

allPackagesInStack :: PackageDBStack -> [InstalledPackageInfo]
allPackagesInStack = concatMap packages

getPkgDatabases :: Verbosity
                -> Bool    -- we are modifying, not reading
                -> Bool    -- use the user db
                -> Bool    -- read caches, if available
                -> Bool    -- expand vars, like ${pkgroot} and $topdir
                -> [Flag]
                -> IO (PackageDBStack, 
                          -- the real package DB stack: [global,user] ++ 
                          -- DBs specified on the command line with -f.
                       Maybe FilePath,
                          -- which one to modify, if any
                       PackageDBStack)
                          -- the package DBs specified on the command
                          -- line, or [global,user] otherwise.  This
                          -- is used as the list of package DBs for
                          -- commands that just read the DB, such as 'list'.

getPkgDatabases verbosity modify use_user use_cache expand_vars my_flags = do
  -- first we determine the location of the global package config.  On Windows,
  -- this is found relative to the ghc-pkg.exe binary, whereas on Unix the
  -- location is passed to the binary using the --global-package-db flag by the
  -- wrapper script.
  let err_msg = "missing --global-package-db option, location of global package database unknown\n"
  global_conf <-
     case [ f | FlagGlobalConfig f <- my_flags ] of
        [] -> do mb_dir <- getLibDir
                 case mb_dir of
                   Nothing  -> die err_msg
                   Just dir -> do
                     r <- lookForPackageDBIn dir
                     case r of
                       Nothing -> die ("Can't find package database in " ++ dir)
                       Just path -> return path
        fs -> return (last fs)

  -- The value of the $topdir variable used in some package descriptions
  -- Note that the way we calculate this is slightly different to how it
  -- is done in ghc itself. We rely on the convention that the global
  -- package db lives in ghc's libdir.
  top_dir <- absolutePath (takeDirectory global_conf)

  -- get the location of the user package database, and create it if necessary
  -- getAppUserDataDirectory can fail (e.g. if $HOME isn't set)
  e_appdir <- tryIO $ getAppUserDataDirectory "ghc"

  mb_user_conf <-
    case e_appdir of
        Left _    -> return Nothing
        Right appdir -> do
          let subdir = targetARCH ++ '-':targetOS ++ '-':Version.version
              dir = appdir </> subdir
          r <- lookForPackageDBIn dir
          case r of
            Nothing -> return (Just (dir </> "package.conf.d", False))
            Just f  -> return (Just (f, True))

  -- If the user database exists, and for "use_user" commands (which includes
  -- "ghc-pkg check" and all commands that modify the db) we will attempt to
  -- use the user db.
  let sys_databases
        | Just (user_conf,user_exists) <- mb_user_conf,
          use_user || user_exists = [user_conf, global_conf]
        | otherwise               = [global_conf]

  e_pkg_path <- tryIO (System.Environment.getEnv "GHC_PACKAGE_PATH")
  let env_stack =
        case e_pkg_path of
                Left  _ -> sys_databases
                Right path
                  | not (null path) && isSearchPathSeparator (last path)
                  -> splitSearchPath (init path) ++ sys_databases
                  | otherwise
                  -> splitSearchPath path

        -- The "global" database is always the one at the bottom of the stack.
        -- This is the database we modify by default.
      virt_global_conf = last env_stack

  let db_flags = [ f | Just f <- map is_db_flag my_flags ]
         where is_db_flag FlagGlobal     = Just virt_global_conf
               is_db_flag _              = Nothing

  let flag_db_names | null db_flags = env_stack
                    | otherwise     = reverse (nub db_flags)

  -- For a "modify" command, treat all the databases as
  -- a stack, where we are modifying the top one, but it
  -- can refer to packages in databases further down the
  -- stack.

  -- -f flags on the command line add to the database
  -- stack, unless any of them are present in the stack
  -- already.
  let final_stack = env_stack

  -- the database we actually modify is the one mentioned
  -- rightmost on the command-line.
  let to_modify
        | not modify    = Nothing
        | null db_flags = Just virt_global_conf
        | otherwise     = Just (last db_flags)

  db_stack  <- sequence
    [ do db <- readParseDatabase verbosity mb_user_conf modify use_cache db_path
         if expand_vars then return (mungePackageDBPaths top_dir db)
                        else return db
    | db_path <- final_stack ]

  let flag_db_stack = [ db | db_name <- flag_db_names,
                        db <- db_stack, location db == db_name ]

  when (verbosity > Normal) $ do
    infoLn ("db stack: " ++ show (map location db_stack))
    infoLn ("modifying: " ++ show to_modify)
    infoLn ("flag db stack: " ++ show (map location flag_db_stack))

  return (db_stack, to_modify, flag_db_stack)


lookForPackageDBIn :: FilePath -> IO (Maybe FilePath)
lookForPackageDBIn dir = do
  let path_dir = dir </> "package.conf.d"
  exists_dir <- doesDirectoryExist path_dir
  if exists_dir then return (Just path_dir) else do
    let path_file = dir </> "package.conf"
    exists_file <- doesFileExist path_file
    if exists_file then return (Just path_file) else return Nothing

readParseDatabase :: Verbosity
                  -> Maybe (FilePath,Bool)
                  -> Bool -- we will be modifying, not just reading
                  -> Bool -- use cache
                  -> FilePath
                  -> IO PackageDB

readParseDatabase verbosity mb_user_conf modify use_cache path
  -- the user database (only) is allowed to be non-existent
  | Just (user_conf,False) <- mb_user_conf, path == user_conf
  = mkPackageDB []
  | otherwise
  = do e <- tryIO $ getDirectoryContents path
       case e of
         Left err
           | ioeGetErrorType err == InappropriateType ->
              die ("ghc no longer supports single-file style package databases "
                ++ "(" ++ path ++ ") use 'ghc-pkg init' to create the database "
                ++ "with the correct format.")
           | otherwise -> ioError err
         Right fs
           | not use_cache -> ignore_cache (const $ return ())
           | otherwise -> do
              let cache = path </> cachefilename
              tdir     <- getModificationTime path
              e_tcache <- tryIO $ getModificationTime cache
              case e_tcache of
                Left ex -> do
                  whenReportCacheErrors $
                    if isDoesNotExistError ex
                      then do
                        warn ("WARNING: cache does not exist: " ++ cache)
                        warn ("ghc will fail to read this package db. " ++
                              "Use 'ghc-pkg recache' to fix.")
                      else do
                        warn ("WARNING: cache cannot be read: " ++ show ex)
                        warn "ghc will fail to read this package db."
                  ignore_cache (const $ return ())
                Right tcache -> do
                  let compareTimestampToCache file =
                          when (verbosity >= Verbose) $ do
                              tFile <- getModificationTime file
                              compareTimestampToCache' file tFile
                      compareTimestampToCache' file tFile = do
                          let rel = case tcache `compare` tFile of
                                    LT -> " (NEWER than cache)"
                                    GT -> " (older than cache)"
                                    EQ -> " (same as cache)"
                          warn ("Timestamp " ++ show tFile
                             ++ " for " ++ file ++ rel)
                  when (verbosity >= Verbose) $ do
                      warn ("Timestamp " ++ show tcache ++ " for " ++ cache)
                      compareTimestampToCache' path tdir
                  if tcache >= tdir
                      then do
                          when (verbosity > Normal) $
                             infoLn ("using cache: " ++ cache)
                          pkgs <- GhcPkg.readPackageDbForGhcPkg cache
                          mkPackageDB pkgs
                      else do
                          whenReportCacheErrors $ do
                              warn ("WARNING: cache is out of date: " ++ cache)
                              warn ("ghc will see an old view of this " ++
                                    "package db. Use 'ghc-pkg recache' to fix.")
                          ignore_cache compareTimestampToCache
            where
                 ignore_cache :: (FilePath -> IO ()) -> IO PackageDB
                 ignore_cache checkTime = do
                     let confs = filter (".conf" `isSuffixOf`) fs
                         doFile f = do checkTime f
                                       parseSingletonPackageConf verbosity f
                     pkgs <- mapM doFile $ map (path </>) confs
                     mkPackageDB pkgs

                 -- We normally report cache errors for read-only commands,
                 -- since modify commands because will usually fix the cache.
                 whenReportCacheErrors =
                     when (   verbosity >  Normal
                           || verbosity >= Normal && not modify)
  where
    mkPackageDB pkgs = do
      path_abs <- absolutePath path
      return PackageDB {
        location = path,
        locationAbsolute = path_abs,
        packages = pkgs
      }

parseSingletonPackageConf :: Verbosity -> FilePath -> IO InstalledPackageInfo
parseSingletonPackageConf verbosity file = do
  when (verbosity > Normal) $ infoLn ("reading package config: " ++ file)
  readUTF8File file >>= fmap fst . parsePackageInfo

cachefilename :: FilePath
cachefilename = "package.cache"

mungePackageDBPaths :: FilePath -> PackageDB -> PackageDB
mungePackageDBPaths top_dir db@PackageDB { packages = pkgs } =
    db { packages = map (mungePackagePaths top_dir pkgroot) pkgs }
  where
    pkgroot = takeDirectory (locationAbsolute db)    
    -- It so happens that for both styles of package db ("package.conf"
    -- files and "package.conf.d" dirs) the pkgroot is the parent directory
    -- ${pkgroot}/package.conf  or  ${pkgroot}/package.conf.d/

-- TODO: This code is duplicated in compiler/main/Packages.lhs
mungePackagePaths :: FilePath -> FilePath
                  -> InstalledPackageInfo -> InstalledPackageInfo
-- Perform path/URL variable substitution as per the Cabal ${pkgroot} spec
-- (http://www.haskell.org/pipermail/libraries/2009-May/011772.html)
-- Paths/URLs can be relative to ${pkgroot} or ${pkgrooturl}.
-- The "pkgroot" is the directory containing the package database.
--
-- Also perform a similar substitution for the older GHC-specific
-- "$topdir" variable. The "topdir" is the location of the ghc
-- installation (obtained from the -B option).
mungePackagePaths top_dir pkgroot pkg =
    pkg {
      importDirs  = munge_paths (importDirs pkg),
      includeDirs = munge_paths (includeDirs pkg),
      libraryDirs = munge_paths (libraryDirs pkg),
      frameworkDirs = munge_paths (frameworkDirs pkg),
      haddockInterfaces = munge_paths (haddockInterfaces pkg),
                     -- haddock-html is allowed to be either a URL or a file
      haddockHTMLs = munge_paths (munge_urls (haddockHTMLs pkg))
    }
  where
    munge_paths = map munge_path
    munge_urls  = map munge_url

    munge_path p
      | Just p' <- stripVarPrefix "${pkgroot}" p = pkgroot ++ p'
      | Just p' <- stripVarPrefix "$topdir"    p = top_dir ++ p'
      | otherwise                                = p

    munge_url p
      | Just p' <- stripVarPrefix "${pkgrooturl}" p = toUrlPath pkgroot p'
      | Just p' <- stripVarPrefix "$httptopdir"   p = toUrlPath top_dir p'
      | otherwise                                   = p

    toUrlPath r p = "file:///"
                 -- URLs always use posix style '/' separators:
                 ++ FilePath.Posix.joinPath
                        (r : -- We need to drop a leading "/" or "\\"
                             -- if there is one:
                             dropWhile (all isPathSeparator)
                                       (FilePath.splitDirectories p))

    -- We could drop the separator here, and then use </> above. However,
    -- by leaving it in and using ++ we keep the same path separator
    -- rather than letting FilePath change it to use \ as the separator
    stripVarPrefix var path = case stripPrefix var path of
                              Just [] -> Just []
                              Just cs@(c : _) | isPathSeparator c -> Just cs
                              _ -> Nothing


-- -----------------------------------------------------------------------------
-- Registering

parsePackageInfo
        :: String
        -> IO (InstalledPackageInfo, [ValidateWarning])
parsePackageInfo str =
  case parseInstalledPackageInfo str of
    ParseOk warnings ok -> return (mungePackageInfo ok, ws)
      where
        ws = [ msg | PWarning msg <- warnings
                   , not ("Unrecognized field pkgroot" `isPrefixOf` msg) ]
    ParseFailed err -> case locatedErrorMsg err of
                           (Nothing, s) -> die s
                           (Just l, s) -> die (show l ++ ": " ++ s)

mungePackageInfo :: InstalledPackageInfo -> InstalledPackageInfo
mungePackageInfo ipi = ipi { packageKey = packageKey' }
  where
    packageKey'
      | OldPackageKey (PackageIdentifier (PackageName "") _) <- packageKey ipi
          = OldPackageKey (sourcePackageId ipi)
      | otherwise = packageKey ipi

-- -----------------------------------------------------------------------------
-- Making changes to a package database

data DBOp = RemovePackage InstalledPackageInfo
          | AddPackage    InstalledPackageInfo
          | ModifyPackage InstalledPackageInfo

changeDB :: Verbosity -> [DBOp] -> PackageDB -> IO ()
changeDB verbosity cmds db = do
  let db' = updateInternalDB db cmds
  createDirectoryIfMissing True (location db)
  changeDBDir verbosity cmds db'

updateInternalDB :: PackageDB -> [DBOp] -> PackageDB
updateInternalDB db cmds = db{ packages = foldl do_cmd (packages db) cmds }
 where
  do_cmd pkgs (RemovePackage p) = 
    filter ((/= installedPackageId p) . installedPackageId) pkgs
  do_cmd pkgs (AddPackage p) = p : pkgs
  do_cmd pkgs (ModifyPackage p) = 
    do_cmd (do_cmd pkgs (RemovePackage p)) (AddPackage p)
    

changeDBDir :: Verbosity -> [DBOp] -> PackageDB -> IO ()
changeDBDir verbosity cmds db = do
  mapM_ do_cmd cmds
  updateDBCache verbosity db
 where
  do_cmd (RemovePackage p) = do
    let file = location db </> display (installedPackageId p) <.> "conf"
    when (verbosity > Normal) $ infoLn ("removing " ++ file)
    removeFileSafe file
  do_cmd (AddPackage p) = do
    let file = location db </> display (installedPackageId p) <.> "conf"
    when (verbosity > Normal) $ infoLn ("writing " ++ file)
    writeFileUtf8Atomic file (showInstalledPackageInfo p)
  do_cmd (ModifyPackage p) = 
    do_cmd (AddPackage p)

updateDBCache :: Verbosity -> PackageDB -> IO ()
updateDBCache verbosity db = do
  let filename = location db </> cachefilename

      pkgsCabalFormat :: [InstalledPackageInfo]
      pkgsCabalFormat = packages db

      pkgsGhcCacheFormat :: [PackageCacheFormat]
      pkgsGhcCacheFormat = map convertPackageInfoToCacheFormat pkgsCabalFormat

  when (verbosity > Normal) $
      infoLn ("writing cache " ++ filename)
  GhcPkg.writePackageDb filename pkgsGhcCacheFormat pkgsCabalFormat
    `catchIO` \e ->
      if isPermissionError e
      then die (filename ++ ": you don't have permission to modify this file")
      else ioError e
  -- See Note [writeAtomic leaky abstraction]
  -- Cross-platform "touch". This only works if filename is not empty, and not
  -- open for writing already.
  -- TODO. When the Win32 or directory packages have either a touchFile or a
  -- setModificationTime function, use one of those.
  withBinaryFile filename ReadWriteMode $ \handle -> do
      c <- hGetChar handle
      hSeek handle AbsoluteSeek 0
      hPutChar handle c

type PackageCacheFormat = GhcPkg.InstalledPackageInfo
                            String     -- installed package id
                            String     -- src package id
                            String     -- package name
                            String     -- package key
                            ModuleName -- module name

convertPackageInfoToCacheFormat :: InstalledPackageInfo -> PackageCacheFormat
convertPackageInfoToCacheFormat pkg =
    GhcPkg.InstalledPackageInfo {
       GhcPkg.installedPackageId = display (installedPackageId pkg),
       GhcPkg.sourcePackageId    = display (sourcePackageId pkg),
       GhcPkg.packageName        = display (packageName pkg),
       GhcPkg.packageVersion     = packageVersion pkg,
       GhcPkg.packageKey         = display (packageKey pkg),
       GhcPkg.depends            = map display (depends pkg),
       GhcPkg.importDirs         = importDirs pkg,
       GhcPkg.hsLibraries        = hsLibraries pkg,
       GhcPkg.extraLibraries     = extraLibraries pkg,
       GhcPkg.extraGHCiLibraries = extraGHCiLibraries pkg,
       GhcPkg.libraryDirs        = libraryDirs pkg,
       GhcPkg.frameworks         = frameworks pkg,
       GhcPkg.frameworkDirs      = frameworkDirs pkg,
       GhcPkg.ldOptions          = ldOptions pkg,
       GhcPkg.ccOptions          = ccOptions pkg,
       GhcPkg.includes           = includes pkg,
       GhcPkg.includeDirs        = includeDirs pkg,
       GhcPkg.haddockInterfaces  = haddockInterfaces pkg,
       GhcPkg.haddockHTMLs       = haddockHTMLs pkg,
       GhcPkg.exposedModules     = map convertExposed (exposedModules pkg),
       GhcPkg.hiddenModules      = hiddenModules pkg,
       GhcPkg.instantiatedWith   = map convertInst (instantiatedWith pkg),
       GhcPkg.exposed            = exposed pkg,
       GhcPkg.trusted            = trusted pkg
    }
  where convertExposed (ExposedModule n reexport sig) =
            GhcPkg.ExposedModule n (fmap convertOriginal reexport)
                                   (fmap convertOriginal sig)
        convertOriginal (OriginalModule ipid m) =
            GhcPkg.OriginalModule (display ipid) m
        convertInst (m, o) = (m, convertOriginal o)

instance GhcPkg.BinaryStringRep ModuleName where
  fromStringRep = ModuleName.fromString . fromUTF8 . BS.unpack
  toStringRep   = BS.pack . toUTF8 . display

instance GhcPkg.BinaryStringRep String where
  fromStringRep = fromUTF8 . BS.unpack
  toStringRep   = BS.pack . toUTF8


-- -----------------------------------------------------------------------------
-- Exposing, Hiding, Trusting, Distrusting, Unregistering are all similar

recache :: Verbosity -> [Flag] -> IO ()
recache verbosity my_flags = do
  (db_stack, Just to_modify, _flag_dbs) <- 
     getPkgDatabases verbosity True{-modify-} True{-use user-} False{-no cache-}
                               False{-expand vars-} my_flags
  let
        db_to_operate_on = my_head "recache" $
                           filter ((== to_modify).location) db_stack
  --
  changeDB verbosity [] db_to_operate_on

-- -----------------------------------------------------------------------------
-- Listing packages

simplePackageList :: [Flag] -> [InstalledPackageInfo] -> IO ()
simplePackageList my_flags pkgs = do
   let showPkg = display
       -- Sort using instance Ord PackageId
       strs = map showPkg $ sort $ map sourcePackageId pkgs
   when (not (null pkgs)) $
      hPutStrLn stdout $ concat $ intersperse " " strs

-- -----------------------------------------------------------------------------
-- Describe

-- PackageId is can have globVersion for the version
findPackages :: PackageDBStack -> PackageArg -> IO [InstalledPackageInfo]
findPackages db_stack pkgarg
  = fmap (concatMap snd) $ findPackagesByDB db_stack pkgarg

findPackagesByDB :: PackageDBStack -> PackageArg
                 -> IO [(PackageDB, [InstalledPackageInfo])]
findPackagesByDB db_stack pkgarg
  = case [ (db, matched)
         | db <- db_stack,
           let matched = filter (pkgarg `matchesPkg`) (packages db),
           not (null matched) ] of
        [] -> die ("cannot find package " ++ pkg_msg pkgarg)
        ps -> return ps
  where
        pkg_msg (Id pkgid)           = display pkgid
        pkg_msg (PkgKey pk)          = display pk
        pkg_msg (IPId ipid)          = display ipid
        pkg_msg (Substring pkgpat _) = "matching " ++ pkgpat

matches :: PackageIdentifier -> PackageIdentifier -> Bool
pid `matches` pid'
  = (pkgName pid == pkgName pid')
    && (pkgVersion pid == pkgVersion pid' || not (realVersion pid))

realVersion :: PackageIdentifier -> Bool
realVersion pkgid = versionBranch (pkgVersion pkgid) /= []
  -- when versionBranch == [], this is a glob

matchesPkg :: PackageArg -> InstalledPackageInfo -> Bool
(Id pid)        `matchesPkg` pkg = pid `matches` sourcePackageId pkg
(PkgKey pk)     `matchesPkg` pkg = pk == packageKey pkg
(IPId ipid)     `matchesPkg` pkg = ipid == installedPackageId pkg
(Substring _ m) `matchesPkg` pkg = m (display (sourcePackageId pkg))

-- -----------------------------------------------------------------------------
-- Check: Check consistency of installed packages

checkConsistency :: Verbosity -> [Flag] -> IO ()
checkConsistency verbosity my_flags = do
  (db_stack, _, _) <- 
         getPkgDatabases verbosity False{-modify-} True{-use user-}
                                   True{-use cache-} True{-expand vars-}
                                   my_flags
         -- although check is not a modify command, we do need to use the user
         -- db, because we may need it to verify package deps.

  let simple_output = False

  let pkgs = allPackagesInStack db_stack

      checkPackage p = do
         (_,es,ws) <- runValidate $ checkPackageConfig p verbosity db_stack
                                                       False True True
         if null es
            then do when (not simple_output) $ do
                      _ <- reportValidateErrors [] ws "" Nothing
                      return ()
                    return []
            else do
              when (not simple_output) $ do
                  reportError ("There are problems in package " ++ display (sourcePackageId p) ++ ":")
                  _ <- reportValidateErrors es ws "  " Nothing
                  return ()
              return [p]

  broken_pkgs <- concat `fmap` mapM checkPackage pkgs

  let filterOut pkgs1 pkgs2 = filter not_in pkgs2
        where not_in p = sourcePackageId p `notElem` all_ps
              all_ps = map sourcePackageId pkgs1

  let not_broken_pkgs = filterOut broken_pkgs pkgs
      (_, trans_broken_pkgs) = closure [] not_broken_pkgs
      all_broken_pkgs = broken_pkgs ++ trans_broken_pkgs

  when (not (null all_broken_pkgs)) $ do
    if simple_output
      then simplePackageList my_flags all_broken_pkgs
      else do
       reportError ("\nThe following packages are broken, either because they have a problem\n"++
                "listed above, or because they depend on a broken package.")
       mapM_ (hPutStrLn stderr . display . sourcePackageId) all_broken_pkgs

  when (not (null all_broken_pkgs)) $ exitWith (ExitFailure 1)


closure :: [InstalledPackageInfo] -> [InstalledPackageInfo]
        -> ([InstalledPackageInfo], [InstalledPackageInfo])
closure pkgs db_stack = go pkgs db_stack
 where
   go avail not_avail =
     case partition (depsAvailable avail) not_avail of
        ([],        not_avail') -> (avail, not_avail')
        (new_avail, not_avail') -> go (new_avail ++ avail) not_avail'

   depsAvailable :: [InstalledPackageInfo] -> InstalledPackageInfo
                 -> Bool
   depsAvailable pkgs_ok pkg = null dangling
        where dangling = filter (`notElem` pids) (depends pkg)
              pids = map installedPackageId pkgs_ok

        -- we want mutually recursive groups of package to show up
        -- as broken. (#1750)

brokenPackages :: [InstalledPackageInfo] -> [InstalledPackageInfo]
brokenPackages pkgs = snd (closure [] pkgs)

-----------------------------------------------------------------------------
-- Sanity-check a new package config, and automatically build GHCi libs
-- if requested.

type ValidateError   = (Force,String)
type ValidateWarning = String

newtype Validate a = V { runValidate :: IO (a, [ValidateError],[ValidateWarning]) }

instance Functor Validate where
    fmap = liftM

instance Applicative Validate where
    pure = return
    (<*>) = ap

instance Monad Validate where
   return a = V $ return (a, [], [])
   m >>= k = V $ do
      (a, es, ws) <- runValidate m
      (b, es', ws') <- runValidate (k a)
      return (b,es++es',ws++ws')

verror :: Force -> String -> Validate ()
verror f s = V (return ((),[(f,s)],[]))

vwarn :: String -> Validate ()
vwarn s = V (return ((),[],["Warning: " ++ s]))

liftIO :: IO a -> Validate a
liftIO k = V (k >>= \a -> return (a,[],[]))

-- returns False if we should die
reportValidateErrors :: [ValidateError] -> [ValidateWarning]
                     -> String -> Maybe Force -> IO Bool
reportValidateErrors es ws prefix mb_force = do
  mapM_ (warn . (prefix++)) ws
  oks <- mapM report es
  return (and oks)
  where
    report (f,s)
      | Just force <- mb_force
      = if (force >= f)
           then do reportError (prefix ++ s ++ " (ignoring)")
                   return True
           else if f < CannotForce
                   then do reportError (prefix ++ s ++ " (use --force to override)")
                           return False
                   else do reportError err
                           return False
      | otherwise = do reportError err
                       return False
      where
             err = prefix ++ s

validatePackageConfig :: InstalledPackageInfo
                      -> Verbosity
                      -> PackageDBStack
                      -> Bool   -- auto-ghc-libs
                      -> Bool   -- multi_instance
                      -> Bool   -- update, or check
                      -> Force
                      -> IO ()
validatePackageConfig pkg verbosity db_stack auto_ghci_libs
                      multi_instance update force = do
  (_,es,ws) <- runValidate $
                 checkPackageConfig pkg verbosity db_stack
                                    auto_ghci_libs multi_instance update
  ok <- reportValidateErrors es ws (display (sourcePackageId pkg) ++ ": ") (Just force)
  when (not ok) $ exitWith (ExitFailure 1)

checkPackageConfig :: InstalledPackageInfo
                      -> Verbosity
                      -> PackageDBStack
                      -> Bool   -- auto-ghc-libs
                      -> Bool   -- multi_instance
                      -> Bool   -- update, or check
                      -> Validate ()
checkPackageConfig pkg verbosity db_stack auto_ghci_libs
                   multi_instance update = do
  checkInstalledPackageId pkg db_stack update
  checkPackageId pkg
  checkPackageKey pkg
  checkDuplicates db_stack pkg multi_instance update
  mapM_ (checkDep db_stack) (depends pkg)
  checkDuplicateDepends (depends pkg)
  mapM_ (checkDir False "import-dirs")  (importDirs pkg)
  mapM_ (checkDir True  "library-dirs") (libraryDirs pkg)
  mapM_ (checkDir True  "include-dirs") (includeDirs pkg)
  mapM_ (checkDir True  "framework-dirs") (frameworkDirs pkg)
  mapM_ (checkFile   True "haddock-interfaces") (haddockInterfaces pkg)
  mapM_ (checkDirURL True "haddock-html")       (haddockHTMLs pkg)
  checkDuplicateModules pkg
  checkExposedModules db_stack pkg
  checkOtherModules pkg
  mapM_ (checkHSLib verbosity (libraryDirs pkg) auto_ghci_libs) (hsLibraries pkg)
  -- ToDo: check these somehow?
  --    extra_libraries :: [String],
  --    c_includes      :: [String],

checkInstalledPackageId :: InstalledPackageInfo -> PackageDBStack -> Bool 
                        -> Validate ()
checkInstalledPackageId ipi db_stack update = do
  let ipid@(InstalledPackageId str) = installedPackageId ipi
  when (null str) $ verror CannotForce "missing id field"
  let dups = [ p | p <- allPackagesInStack db_stack, 
                   installedPackageId p == ipid ]
  when (not update && not (null dups)) $
    verror CannotForce $
        "package(s) with this id already exist: " ++ 
         unwords (map (display.packageId) dups)

-- When the package name and version are put together, sometimes we can
-- end up with a package id that cannot be parsed.  This will lead to
-- difficulties when the user wants to refer to the package later, so
-- we check that the package id can be parsed properly here.
checkPackageId :: InstalledPackageInfo -> Validate ()
checkPackageId ipi =
  let str = display (sourcePackageId ipi) in
  case [ x :: PackageIdentifier | (x,ys) <- readP_to_S parse str, all isSpace ys ] of
    [_] -> return ()
    []  -> verror CannotForce ("invalid package identifier: " ++ str)
    _   -> verror CannotForce ("ambiguous package identifier: " ++ str)

checkPackageKey :: InstalledPackageInfo -> Validate ()
checkPackageKey ipi =
  let str = display (packageKey ipi) in
  case [ x :: PackageKey | (x,ys) <- readP_to_S parse str, all isSpace ys ] of
    [_] -> return ()
    []  -> verror CannotForce ("invalid package key: " ++ str)
    _   -> verror CannotForce ("ambiguous package key: " ++ str)

checkDuplicates :: PackageDBStack -> InstalledPackageInfo
                -> Bool -> Bool-> Validate ()
checkDuplicates db_stack pkg multi_instance update = do
  let
        pkgid = sourcePackageId pkg
        pkgs  = packages (head db_stack)
  --
  -- Check whether this package id already exists in this DB
  --
  when (not update && not multi_instance
                   && (pkgid `elem` map sourcePackageId pkgs)) $
       verror CannotForce $
          "package " ++ display pkgid ++ " is already installed"

  let
        uncasep = map toLower . display
        dups = filter ((== uncasep pkgid) . uncasep) (map sourcePackageId pkgs)

  when (not update && not (null dups)) $ verror ForceAll $
        "Package names may be treated case-insensitively in the future.\n"++
        "Package " ++ display pkgid ++
        " overlaps with: " ++ unwords (map display dups)

checkDir, checkFile, checkDirURL :: Bool -> String -> FilePath -> Validate ()
checkDir  = checkPath False True
checkFile = checkPath False False
checkDirURL = checkPath True True

checkPath :: Bool -> Bool -> Bool -> String -> FilePath -> Validate ()
checkPath url_ok is_dir warn_only thisfield d
 | url_ok && ("http://"  `isPrefixOf` d
           || "https://" `isPrefixOf` d) = return ()

 | url_ok
 , Just d' <- stripPrefix "file://" d
 = checkPath False is_dir warn_only thisfield d'

   -- Note: we don't check for $topdir/${pkgroot} here. We rely on these
   -- variables having been expanded already, see mungePackagePaths.

 | isRelative d = verror ForceFiles $
                     thisfield ++ ": " ++ d ++ " is a relative path which "
                  ++ "makes no sense (as there is nothing for it to be "
                  ++ "relative to). You can make paths relative to the "
                  ++ "package database itself by using ${pkgroot}."
        -- relative paths don't make any sense; #4134
 | otherwise = do
   there <- liftIO $ if is_dir then doesDirectoryExist d else doesFileExist d
   when (not there) $
       let msg = thisfield ++ ": " ++ d ++ " doesn't exist or isn't a "
                                        ++ if is_dir then "directory" else "file"
       in
       if warn_only 
          then vwarn msg
          else verror ForceFiles msg

checkDep :: PackageDBStack -> InstalledPackageId -> Validate ()
checkDep db_stack pkgid
  | pkgid `elem` pkgids = return ()
  | otherwise = verror ForceAll ("dependency \"" ++ display pkgid
                                 ++ "\" doesn't exist")
  where
        all_pkgs = allPackagesInStack db_stack
        pkgids = map installedPackageId all_pkgs

checkDuplicateDepends :: [InstalledPackageId] -> Validate ()
checkDuplicateDepends deps
  | null dups = return ()
  | otherwise = verror ForceAll ("package has duplicate dependencies: " ++
                                     unwords (map display dups))
  where
       dups = [ p | (p:_:_) <- group (sort deps) ]

checkHSLib :: Verbosity -> [String] -> Bool -> String -> Validate ()
checkHSLib verbosity dirs auto_ghci_libs lib = do
  let batch_lib_file = "lib" ++ lib ++ ".a"
      filenames = ["lib" ++ lib ++ ".a",
                   "lib" ++ lib ++ ".p_a",
                   "lib" ++ lib ++ "-ghc" ++ Version.version ++ ".so",
                   "lib" ++ lib ++ "-ghc" ++ Version.version ++ ".dylib",
                            lib ++ "-ghc" ++ Version.version ++ ".dll"]
  m <- liftIO $ doesFileExistOnPath filenames dirs
  case m of
    Nothing -> verror ForceFiles ("cannot find any of " ++ show filenames ++
                                  " on library path")
    Just dir -> liftIO $ checkGHCiLib verbosity dir batch_lib_file lib auto_ghci_libs

doesFileExistOnPath :: [FilePath] -> [FilePath] -> IO (Maybe FilePath)
doesFileExistOnPath filenames paths = go fullFilenames
  where fullFilenames = [ (path, path </> filename)
                        | filename <- filenames
                        , path <- paths ]
        go []             = return Nothing
        go ((p, fp) : xs) = do b <- doesFileExist fp
                               if b then return (Just p) else go xs

-- | Perform validation checks (module file existence checks) on the
-- @hidden-modules@ field.
checkOtherModules :: InstalledPackageInfo -> Validate ()
checkOtherModules pkg = mapM_ (checkModuleFile pkg) (hiddenModules pkg)

-- | Perform validation checks (module file existence checks and module
-- reexport checks) on the @exposed-modules@ field.
checkExposedModules :: PackageDBStack -> InstalledPackageInfo -> Validate ()
checkExposedModules db_stack pkg =
  mapM_ checkExposedModule (exposedModules pkg)
  where
    checkExposedModule (ExposedModule modl reexport _sig) = do
      let checkOriginal = checkModuleFile pkg modl
          checkReexport = checkOriginalModule "module reexport" db_stack pkg
      maybe checkOriginal checkReexport reexport

-- | Validates the existence of an appropriate @hi@ file associated with
-- a module.  Used for both @hidden-modules@ and @exposed-modules@ which
-- are not reexports.
checkModuleFile :: InstalledPackageInfo -> ModuleName -> Validate ()
checkModuleFile pkg modl =
      -- there's no interface file for GHC.Prim
      unless (modl == ModuleName.fromString "GHC.Prim") $ do
      let files = [ ModuleName.toFilePath modl <.> extension
                  | extension <- ["hi", "p_hi", "dyn_hi" ] ]
      m <- liftIO $ doesFileExistOnPath files (importDirs pkg)
      when (isNothing m) $
         verror ForceFiles ("cannot find any of " ++ show files)

-- | Validates that @exposed-modules@ and @hidden-modules@ do not have duplicate
-- entries.
-- ToDo: this needs updating for signatures: signatures can validly show up
-- multiple times in the @exposed-modules@ list as long as their backing
-- implementations agree.
checkDuplicateModules :: InstalledPackageInfo -> Validate ()
checkDuplicateModules pkg
  | null dups = return ()
  | otherwise = verror ForceAll ("package has duplicate modules: " ++
                                     unwords (map display dups))
  where
    dups = [ m | (m:_:_) <- group (sort mods) ]
    mods = map exposedName (exposedModules pkg) ++ hiddenModules pkg

-- | Validates an original module entry, either the origin of a module reexport
-- or the backing implementation of a signature, by checking that it exists,
-- really is an original definition, and is accessible from the dependencies of
-- the package.
-- ToDo: If the original module in question is a backing signature
-- implementation, then we should also check that the original module in
-- question is NOT a signature (however, if it is a reexport, then it's fine
-- for the original module to be a signature.)
checkOriginalModule :: String
                    -> PackageDBStack
                    -> InstalledPackageInfo
                    -> OriginalModule
                    -> Validate ()
checkOriginalModule fieldName db_stack pkg
    (OriginalModule definingPkgId definingModule) =
  let mpkg = if definingPkgId == installedPackageId pkg
              then Just pkg
              else PackageIndex.lookupInstalledPackageId ipix definingPkgId
  in case mpkg of
      Nothing
           -> verror ForceAll (fieldName ++ " refers to a non-existent " ++
                               "defining package: " ++
                                       display definingPkgId)

      Just definingPkg
        | not (isIndirectDependency definingPkgId)
           -> verror ForceAll (fieldName ++ " refers to a defining  " ++
                               "package that is not a direct (or indirect) " ++
                               "dependency of this package: " ++
                                       display definingPkgId)

        | otherwise
        -> case find ((==definingModule).exposedName)
                     (exposedModules definingPkg) of
            Nothing ->
              verror ForceAll (fieldName ++ " refers to a module " ++
                               display definingModule ++ " " ++
                               "that is not exposed in the " ++
                               "defining package " ++ display definingPkgId)
            Just (ExposedModule {exposedReexport = Just _} ) ->
              verror ForceAll (fieldName ++ " refers to a module " ++
                               display definingModule ++ " " ++
                               "that is reexported but not defined in the " ++
                               "defining package " ++ display definingPkgId)
            _ -> return ()

  where
    all_pkgs = allPackagesInStack db_stack
    ipix     = PackageIndex.fromList all_pkgs

    isIndirectDependency pkgid = fromMaybe False $ do
      thispkg  <- graphVertex (installedPackageId pkg)
      otherpkg <- graphVertex pkgid
      return (Graph.path depgraph thispkg otherpkg)
    (depgraph, _, graphVertex) =
      PackageIndex.dependencyGraph (PackageIndex.insert pkg ipix)


checkGHCiLib :: Verbosity -> String -> String -> String -> Bool -> IO ()
checkGHCiLib verbosity batch_lib_dir batch_lib_file lib auto_build
  | auto_build = autoBuildGHCiLib verbosity batch_lib_dir batch_lib_file ghci_lib_file
  | otherwise  = return ()
 where
    ghci_lib_file = lib <.> "o"

-- automatically build the GHCi version of a batch lib,
-- using ld --whole-archive.

autoBuildGHCiLib :: Verbosity -> String -> String -> String -> IO ()
autoBuildGHCiLib verbosity dir batch_file ghci_file = do
  let ghci_lib_file  = dir ++ '/':ghci_file
      batch_lib_file = dir ++ '/':batch_file
  when (verbosity >= Normal) $
    info ("building GHCi library " ++ ghci_lib_file ++ "...")
#if defined(darwin_HOST_OS)
  r <- rawSystem "ld" ["-r","-x","-o",ghci_lib_file,"-all_load",batch_lib_file]
#elif defined(mingw32_HOST_OS)
  execDir <- getLibDir
  r <- rawSystem (maybe "" (++"/gcc-lib/") execDir++"ld") ["-r","-x","-o",ghci_lib_file,"--whole-archive",batch_lib_file]
#else
  r <- rawSystem "ld" ["-r","-x","-o",ghci_lib_file,"--whole-archive",batch_lib_file]
#endif
  when (r /= ExitSuccess) $ exitWith r
  when (verbosity >= Normal) $
    infoLn (" done.")

-- -----------------------------------------------------------------------------
-- Searching for modules

#if not_yet

findModules :: [FilePath] -> IO [String]
findModules paths =
  mms <- mapM searchDir paths
  return (concat mms)

searchDir path prefix = do
  fs <- getDirectoryEntries path `catchIO` \_ -> return []
  searchEntries path prefix fs

searchEntries path prefix [] = return []
searchEntries path prefix (f:fs)
  | looks_like_a_module  =  do
        ms <- searchEntries path prefix fs
        return (prefix `joinModule` f : ms)
  | looks_like_a_component  =  do
        ms <- searchDir (path </> f) (prefix `joinModule` f)
        ms' <- searchEntries path prefix fs
        return (ms ++ ms')
  | otherwise
        searchEntries path prefix fs

  where
        (base,suffix) = splitFileExt f
        looks_like_a_module =
                suffix `elem` haskell_suffixes &&
                all okInModuleName base
        looks_like_a_component =
                null suffix && all okInModuleName base

okInModuleName c

#endif

-- ---------------------------------------------------------------------------
-- expanding environment variables in the package configuration

expandEnvVars :: String -> Force -> IO String
expandEnvVars str0 force = go str0 ""
 where
   go "" acc = return $! reverse acc
   go ('$':'{':str) acc | (var, '}':rest) <- break close str
        = do value <- lookupEnvVar var
             go rest (reverse value ++ acc)
        where close c = c == '}' || c == '\n' -- don't span newlines
   go (c:str) acc
        = go str (c:acc)

   lookupEnvVar :: String -> IO String
   lookupEnvVar "pkgroot"    = return "${pkgroot}"    -- these two are special,
   lookupEnvVar "pkgrooturl" = return "${pkgrooturl}" -- we don't expand them
   lookupEnvVar nm =
        catchIO (System.Environment.getEnv nm)
           (\ _ -> do dieOrForceAll force ("Unable to expand variable " ++
                                        show nm)
                      return "")

-----------------------------------------------------------------------------

getProgramName :: IO String
getProgramName = liftM (`withoutSuffix` ".bin") getProgName
   where str `withoutSuffix` suff
            | suff `isSuffixOf` str = take (length str - length suff) str
            | otherwise             = str

bye :: String -> IO a
bye s = putStr s >> exitWith ExitSuccess

die :: String -> IO a
die = dieWith 1

dieWith :: Int -> String -> IO a
dieWith ec s = do
  prog <- getProgramName
  reportError (prog ++ ": " ++ s)
  exitWith (ExitFailure ec)

dieOrForceAll :: Force -> String -> IO ()
dieOrForceAll ForceAll s = ignoreError s
dieOrForceAll _other s   = dieForcible s

warn :: String -> IO ()
warn = reportError

-- send info messages to stdout
infoLn :: String -> IO ()
infoLn = putStrLn

info :: String -> IO ()
info = putStr

ignoreError :: String -> IO ()
ignoreError s = reportError (s ++ " (ignoring)")

reportError :: String -> IO ()
reportError s = do hFlush stdout; hPutStrLn stderr s

dieForcible :: String -> IO ()
dieForcible s = die (s ++ " (use --force to override)")

my_head :: String -> [a] -> a
my_head s []      = error s
my_head _ (x : _) = x

-----------------------------------------
-- Cut and pasted from ghc/compiler/main/SysTools

#if defined(mingw32_HOST_OS)
subst :: Char -> Char -> String -> String
subst a b ls = map (\ x -> if x == a then b else x) ls

unDosifyPath :: FilePath -> FilePath
unDosifyPath xs = subst '\\' '/' xs

getLibDir :: IO (Maybe String)
getLibDir = fmap (fmap (</> "lib")) $ getExecDir "/bin/ghc-pkg.exe"

-- (getExecDir cmd) returns the directory in which the current
--                  executable, which should be called 'cmd', is running
-- So if the full path is /a/b/c/d/e, and you pass "d/e" as cmd,
-- you'll get "/a/b/c" back as the result
getExecDir :: String -> IO (Maybe String)
getExecDir cmd =
    getExecPath >>= maybe (return Nothing) removeCmdSuffix
    where initN n = reverse . drop n . reverse
          removeCmdSuffix = return . Just . initN (length cmd) . unDosifyPath

getExecPath :: IO (Maybe String)
getExecPath = try_size 2048 -- plenty, PATH_MAX is 512 under Win32.
  where
    try_size size = allocaArray (fromIntegral size) $ \buf -> do
        ret <- c_GetModuleFileName nullPtr buf size
        case ret of
          0 -> return Nothing
          _ | ret < size -> fmap Just $ peekCWString buf
            | otherwise  -> try_size (size * 2)

foreign import WINDOWS_CCONV unsafe "windows.h GetModuleFileNameW"
  c_GetModuleFileName :: Ptr () -> CWString -> Word32 -> IO Word32
#else
getLibDir :: IO (Maybe String)
getLibDir = return Nothing
#endif

-----------------------------------------
-- Adapted from ghc/compiler/utils/Panic

installSignalHandlers :: IO ()
installSignalHandlers = do
  threadid <- myThreadId
  let
      interrupt = Exception.throwTo threadid
                                    (Exception.ErrorCall "interrupted")
  --
#if !defined(mingw32_HOST_OS)
  _ <- installHandler sigQUIT (Catch interrupt) Nothing
  _ <- installHandler sigINT  (Catch interrupt) Nothing
  return ()
#else
  -- GHC 6.3+ has support for console events on Windows
  -- NOTE: running GHCi under a bash shell for some reason requires
  -- you to press Ctrl-Break rather than Ctrl-C to provoke
  -- an interrupt.  Ctrl-C is getting blocked somewhere, I don't know
  -- why --SDM 17/12/2004
  let sig_handler ControlC = interrupt
      sig_handler Break    = interrupt
      sig_handler _        = return ()

  _ <- installHandler (Catch sig_handler)
  return ()
#endif

#if mingw32_HOST_OS || mingw32_TARGET_OS
throwIOIO :: Exception.IOException -> IO a
throwIOIO = Exception.throwIO
#endif

catchIO :: IO a -> (Exception.IOException -> IO a) -> IO a
catchIO = Exception.catch

tryIO :: IO a -> IO (Either Exception.IOException a)
tryIO = Exception.try

writeFileUtf8Atomic :: FilePath -> String -> IO ()
writeFileUtf8Atomic targetFile content =
  withFileAtomic targetFile $ \h -> do
     hSetEncoding h utf8
     hPutStr h content

-- copied from Cabal's Distribution.Simple.Utils, except that we want
-- to use text files here, rather than binary files.
withFileAtomic :: FilePath -> (Handle -> IO ()) -> IO ()
withFileAtomic targetFile write_content = do
  (newFile, newHandle) <- openNewFile targetDir template
  do  write_content newHandle
      hClose newHandle
#if mingw32_HOST_OS || mingw32_TARGET_OS
      renameFile newFile targetFile
        -- If the targetFile exists then renameFile will fail
        `catchIO` \err -> do
          exists <- doesFileExist targetFile
          if exists
            then do removeFileSafe targetFile
                    -- Big fat hairy race condition
                    renameFile newFile targetFile
                    -- If the removeFile succeeds and the renameFile fails
                    -- then we've lost the atomic property.
            else throwIOIO err
#else
      renameFile newFile targetFile
#endif
   `Exception.onException` do hClose newHandle
                              removeFileSafe newFile
  where
    template = targetName <.> "tmp"
    targetDir | null targetDir_ = "."
              | otherwise       = targetDir_
    --TODO: remove this when takeDirectory/splitFileName is fixed
    --      to always return a valid dir
    (targetDir_,targetName) = splitFileName targetFile

openNewFile :: FilePath -> String -> IO (FilePath, Handle)
openNewFile dir template = do
  -- this was added to System.IO in 6.12.1
  -- we must use this version because the version below opens the file
  -- in binary mode.
  openTempFileWithDefaultPermissions dir template

readUTF8File :: FilePath -> IO String
readUTF8File file = do
  h <- openFile file ReadMode
  -- fix the encoding to UTF-8
  hSetEncoding h utf8
  hGetContents h

-- removeFileSave doesn't throw an exceptions, if the file is already deleted
removeFileSafe :: FilePath -> IO ()
removeFileSafe fn =
  removeFile fn `catchIO` \ e ->
    when (not $ isDoesNotExistError e) $ ioError e

absolutePath :: FilePath -> IO FilePath
absolutePath path = return . normalise . (</> path) =<< getCurrentDirectory


{- Note [writeAtomic leaky abstraction]
GhcPkg.writePackageDb calls writeAtomic, which first writes to a temp file,
and then moves the tempfile to its final destination. This all happens in the
same directory (package.conf.d).
Moving a file doesn't change its modification time, but it *does* change the
modification time of the directory it is placed in. Since we compare the
modification time of the cache file to that of the directory it is in to
decide whether the cache is out-of-date, it will be instantly out-of-date
after creation, if the renaming takes longer than the smallest time difference
that the getModificationTime can measure.

The solution we opt for is a "touch" of the cache file right after it is
created. This resets the modification time of the cache file and the directory
to the current time.

Other possible solutions:
  * backdate the modification time of the directory to the modification time
    of the cachefile. This is what we used to do on posix platforms. An
    observer of the directory would see the modification time of the directory
    jump back in time. Not nice, although in practice probably not a problem.
    Also note that a cross-platform implementation of setModificationTime is
    currently not available.
  * set the modification time of the cache file to the modification time of
    the directory (instead of the curent time). This could also work,
    given that we are the only ones writing to this directory. It would also
    require a high-precision getModificationTime (lower precision times get
    rounded down it seems), or the cache would still be out-of-date.
  * change writeAtomic to create the tempfile outside of the target file's
    directory.
  * create the cachefile outside of the package.conf.d directory in the first
    place. But there are tests and there might be tools that currently rely on
    the package.conf.d/package.cache format.
-}
