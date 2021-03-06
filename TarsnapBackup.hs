{-# LANGUAGE DeriveDataTypeable #-}

{--

Copyright (c) 2010, Andy Irving
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the <organization> nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--}
module TarsnapBackup where

import Data.Time.Calendar
import Data.Time.Calendar.OrdinalDate
import Data.List
import System.Process
import System.Console.CmdArgs
import System.FilePath
import Data.Maybe
import System.Exit

data Frequency
  = Daily
  | Weekly
  | Monthly
  | Auto
  deriving (Read, Show, Eq, Data, Typeable)

doBackup :: Frequency -> Bool -> Bool -> [String] -> Day -> FilePath -> IO ExitCode
doBackup f dry v excl d b =
  readProcessWithExitCode "tarsnap"
                        (dryRun
                         ++ verboseRun
                         ++ excludePatterns
                         ++ ["--print-stats", "-c", "-f", archive_name b, b])
                        [] >>= checkRes
  where
    dryRun = ["--dry-run" | dry]
    verboseRun = ["--verbose" | v]
    checkRes (rc, _, err) =
      case rc of
        ExitFailure eno ->
          error $ "Unable to backup: (" ++ show eno ++ ")\n" ++ err
        ExitSuccess -> putStrLn err >> return rc
    excludePatterns = concatMap (\p -> ["--exclude", p]) excl
    basename d' = last (splitDirectories d') -- /path/to/blah == blah
    -- blah-Frequency-2010-09-11
    archive_name b' = intercalate "-" [basename b', show f, showGregorian d]

-- When doing the cleanup, remove backups which are of the lower frequency
whatCleanup :: Frequency -> Maybe Frequency
whatCleanup = whatType
  where
    whatType Daily = Nothing
    whatType Weekly = Just Daily
    whatType Monthly = Just Weekly
    whatType _ = Nothing

doCleanup :: Frequency -> Bool -> Bool -> String -> Int -> IO ExitCode
doCleanup f dry v b n = readProcessWithExitCode "tarsnap" ["--list-archives"] [] >>= goCleanup
  where
    goCleanup (rc, out, err) =
      case rc of
        ExitFailure _ ->
          error $ "Unable to list archives for cleanup" ++ "\n" ++ err
        ExitSuccess ->
          case getCleanupList b f (lines out) of
            [] -> return rc
            xs -> execCleanup dry v (drop n (reverse xs))

execCleanup :: Bool -> Bool -> [String] -> IO ExitCode
execCleanup dry v l = do
  (rc, _, err) <-
    readProcessWithExitCode "tarsnap" (dryRun ++ verboseRun ++ ["-d", "-f"] ++ intersperse "-f" l) []
  case rc of
    ExitFailure _ -> error err
    ExitSuccess -> putStrLn err >> return rc
  where
    dryRun = ["--dry-run" | dry]
    verboseRun = ["--verbose" | v]


-- from the input list:
-- ["blah-Frequency-2010-09-11", "blah-Frequency-2010-09-12"]
-- strip the "blah-" string if it's an archive of this dir
-- then strip the "Frequency-" string if it's the frequency we're clearing up
-- then remove any Nothing's from the list
getCleanupList :: String -> Frequency -> [String] -> [String]
getCleanupList b f l =
  sort . map ((b ++ "-" ++ show f ++ "-") ++) $
  mapMaybe (stripPrefix (show f ++ "-")) $ mapMaybe (stripPrefix (b ++ "-")) l

-- using System.Console.CmdArgs on account of System.Console.GetOpt being
-- not unlike stabbed repeatedly in the face
data TarsnapBackup = TarsnapBackup
  { frequency :: Frequency
  , exclude :: [String]
  , verbose :: Bool
  , dryrun :: Bool
  , dir :: FilePath
  , cleanup :: Bool
  , retain :: Int
  } deriving (Show, Data, Typeable)

tb :: TarsnapBackup
tb =
  TarsnapBackup
  { frequency = Auto &= opt "Auto" &= help "Force a backup of type (Daily, Weekly, Monthly)"
  , exclude = [] &= typ "PATTERN" &= help "Patterns to exclude"
  , cleanup = True &= help "Cleanup old backups, including this and lower Frequencies"
  , verbose = False &= help "Increase verbosity"
  , dryrun = False &= help "Don't actually do anything. Useful together with the verbose option"
  , retain = 0 &= help "Number of backups to retain of the requested Frequency"
  , dir = "" &= args &= typDir
  } &=
  help "This script manages Tarsnap backups" &=
  summary "(c) Andy Irving <irv@soundforsound.co.uk> 2010-2016"

autoFrequency :: Frequency -> Day -> Frequency
autoFrequency f d = check f
  where
    check Auto
      | month_day == 1 = Monthly -- first day of the month
      | week_day == 0 = Weekly -- first day of the week
      | otherwise = Daily
    check _ = f
    (_, _, month_day) = toGregorian d
    (_, week_day) = sundayStartWeek d
