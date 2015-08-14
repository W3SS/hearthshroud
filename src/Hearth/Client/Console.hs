{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}


module Hearth.Client.Console (
    main
) where


--------------------------------------------------------------------------------


import Control.Applicative
import Control.Error.TH
import Control.Exception hiding (handle)
import Control.Lens hiding (index)
import Control.Lens.Helper
import Control.Lens.Internal.Zoom (Zoomed, Focusing)
import Control.Monad.Prompt hiding (Effect)
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.State.Local
import Data.Char
import Data.Data
import Data.Either
import Data.Function
import Data.List
import Data.Maybe
import Data.NonEmpty
import Data.Ord
import Data.String
import Hearth.Action
import qualified Hearth.Cards as Universe
import Hearth.Client.Console.Render.BoardMinionsColumn
import Hearth.Client.Console.Render.HandColumn
import Hearth.Client.Console.Render.PlayerColumn
import Hearth.Client.Console.SGRString
import Hearth.DebugEvent
import Hearth.Engine
import Hearth.GameEvent
import Hearth.Model hiding (minionName, spellName)
import qualified Hearth.Model as Model
import Hearth.Names
import Hearth.Names.Basic (BasicCardName(TheCoin), BasicHeroPowerName(..))
import Hearth.Names.Hero
import Hearth.Prompt
import Hearth.ShowCard
import Language.Haskell.TH.Syntax (nameBase)
import Prelude hiding (pi, log)
import System.Console.ANSI
import System.Console.Terminal.Size (Window)
import qualified System.Console.Terminal.Size as Window
import System.Environment
import System.Random
import System.Random.Shuffle
import Text.LambdaOptions.Core
import Text.LambdaOptions.Keyword
import Text.LambdaOptions.List
import Text.LambdaOptions.Parseable
import Text.Read (readMaybe)


--------------------------------------------------------------------------------


simpleParse :: (String -> Maybe a) -> [String] -> (Maybe a, Int)
simpleParse parser args = case args of
        [] -> (Nothing, 0)
        s : _ -> case parser s of
            Nothing -> (Nothing, 0)
            Just x -> (Just x, 1)


defaultVerbosity :: Verbosity
defaultVerbosity = GameEventsOnly


data Verbosity
    = Quiet
    | GameEventsOnly
    | DebugLight
    | DebugExhaustive
    deriving (Show, Read, Eq, Ord, Enum, Data, Typeable)


instance Parseable Verbosity where
    parse = simpleParse readMaybe


data Sign = Positive | Negative
    deriving (Show, Eq, Ord, Data, Typeable)


data SignedInt = SignedInt Sign Int -- The Int part should never be negative.
    deriving (Show, Eq, Ord, Data, Typeable)


instance Parseable SignedInt where
    parse = simpleParse $ \case
        s : c : cs -> case isDigit c of
            False -> Nothing
            True -> let
                f = case s of
                    '+' -> fmap $ SignedInt Positive
                    '-' -> fmap $ SignedInt Negative
                    _ -> const Nothing
                in f $ readMaybe $ c : cs
        _ -> Nothing


data NonParseable = NonParseable
    deriving (Data, Typeable)


instance Parseable NonParseable where
    parse _ = (Nothing, 0)


nonParseable :: (Monad m) => NonParseable -> m a
nonParseable _ = $logicError 'nonParseable "This function should not be called."


data TargetType = TargetMinion | TargetPlayer | TargetCharacter
    deriving (Show, Eq, Ord)


data LogState = LogState {
    _loggedLines :: [String],
    _totalLines :: !Int,
    _undisplayedLines :: !Int,
    _tagDepth :: !Int,
    _useShortTag :: !Bool,
    _verbosity :: !Verbosity
} deriving (Show, Eq, Ord)
makeLenses ''LogState


data ConsoleState = ConsoleState {
    _gameSeed :: Maybe Int,
    _runGame :: Bool,
    _pendingTargets :: [SignedInt],
    _playedMinionIdx :: Maybe Int,
    _isAutoplay :: Bool,
    _logState :: LogState
} deriving (Show, Eq, Ord)
makeLenses ''ConsoleState


newtype Console' st a = Console {
    unConsole :: StateT st IO a
} deriving (Functor, Applicative, Monad, MonadIO, MonadState st)


instance MonadReader st (Console' st) where
    ask = get
    local = stateLocal


type Console = Console' ConsoleState


type instance Zoomed (Console' st) = Focusing IO


instance Zoom (Console' st) (Console' st') st st' where
    zoom l = Console . zoom l . unConsole


class LocalQuiet m where
    localQuiet :: m a -> m a


instance LocalQuiet Console where
    localQuiet m = do
        v <- view $ logState.verbosity
        logState.verbosity .= Quiet
        x <- m
        logState.verbosity .= v
        return x


instance LocalQuiet (Hearth Console) where
    localQuiet m = do
        v <- lift $ view $ logState.verbosity
        lift $ logState.verbosity .= Quiet
        x <- m
        lift $ logState.verbosity .= v
        return x


newLogLine :: Console ()
newLogLine = zoom logState $ do
    totalLines += 1
    undisplayedLines += 1
    loggedLines %= ("" :)


appendLogLine :: String -> Console ()
appendLogLine str = logState.loggedLines %= \case
    s : ss -> (s ++ str) : ss
    [] -> $logicError 'appendLogLine "Bad state"


logIndentation :: Console String
logIndentation = do
    n <- view $ logState.tagDepth
    return $ concat $ replicate n "    "


openTag :: String -> [(String, String)] -> Console ()
openTag name attrs = do
    logState.useShortTag >>=. \case
        True -> do
            appendLogLine ">"
            newLogLine
        False -> return ()
    logState.useShortTag .= True
    lead <- logIndentation
    appendLogLine $ lead ++ "<" ++ unwords (name : attrs')
    logState.tagDepth += 1
    where
        showAttr (k, v) = k ++ "=\"" ++ v ++ "\""
        attrs' = map showAttr $ filter (/= ("", "")) attrs


closeTag :: String -> Console ()
closeTag name = do
    logState.tagDepth -= 1
    logState.useShortTag >>=. \case
        True -> do
            appendLogLine "/>"
            newLogLine
        False -> do
            lead <- logIndentation
            appendLogLine $ lead ++ "</" ++ name ++ ">"
            newLogLine
    logState.useShortTag .= False


verbosityGate :: String -> Console () -> Console ()
verbosityGate name m = do
    view (logState.verbosity) >>= \case
        Quiet -> return ()
        GameEventsOnly -> case name of
            ':' : _ -> return ()
            _ -> m
        DebugLight -> case name of
            ':' : rest -> case isLight rest of
                True -> m
                False -> return ()
            _ -> m
        DebugExhaustive -> m
    where
        isLight = (`notElem` lightBanList)
        lightBanList = map nameBase [
            'dynamicAttack,
            'dynamicMaxHealth,
            'getActivePlayerHandle,
            'controllerOf ]


debugEvent :: DebugEvent -> Console ()
debugEvent e = case e of
    DiagnosticMessage message -> let
        name = showName 'DiagnosticMessage
        in verbosityGate name $ do
            openTag name [("message", message)]
            closeTag name
            liftIO $ do
                putStrLn message
                enterToContinue
    FunctionEntered name -> let
        name' = showName name
        in verbosityGate name' $ openTag name' []
    FunctionExited name -> let
        name' = showName name
        in verbosityGate name' $ closeTag name'
    where
        showName = (':' :) . nameBase


gameEvent :: GameSnapshot -> GameEvent -> Console ()
gameEvent snapshot = \case
    GameBegins -> let
        in tag 'GameBegins []
    GameEnds gameResult -> let
        gameResultAttr = ("gameResult", show gameResult)
        in tag 'GameEnds [gameResultAttr]
    DeckShuffled player _ -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
        tag 'DeckShuffled [playerAttr]
    CardDrawn player (deckOrHandCard) _ -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
            cardAttr = ("card", either deckCardName' handCardName' deckOrHandCard)
            resultAttr = ("result", either (const $ show 'Failure) (const $ show Success) deckOrHandCard)
        tag 'CardDrawn [playerAttr, cardAttr, resultAttr]
    UsedHeroPower player power -> do
        playerName <- query $ showHandle player
        let powerName = power^.heroPowerName.to showHeroPowerName
            playerAttr = ("player", playerName)
            powerAttr = ("heroPower", powerName)
        tag 'UsedHeroPower [playerAttr, powerAttr]
    PlayedMinion player minion -> do
        playerName <- query $ showHandle player
        minionName <- query $ showHandle minion
        let playerAttr = ("player", playerName)
            minionAttr = ("minion", minionName)
        tag 'PlayedMinion [playerAttr, minionAttr]
    PlayedSpell player spell -> do
        playerName <- query $ showHandle player
        spellName <- query $ showHandle spell
        let playerAttr = ("player", playerName)
            spellAttr = ("spell", spellName)
        tag 'PlayedSpell [playerAttr, spellAttr]
    TookDamage character (Damage damage) -> do
        characterName <- query $ showHandle character
        let characterAttr = ("character", characterName)
            damageAttr = ("damage", show damage)
        tag 'TookDamage [characterAttr, damageAttr]
    HealthRestored character (Health health) -> do
        characterName <- query $ showHandle character
        let characterAttr = ("character", characterName)
            healthAttr = ("health", show health)
        tag 'HealthRestored [characterAttr, healthAttr]
    GainedArmor player (Armor armor) -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
            armorAttr = ("armor", show armor)
        tag 'GainedArmor [playerAttr, armorAttr]
    Transformed oldMinion newMinion -> do
        oldMinionName <- query $ showHandle oldMinion
        let newMinionName = showCardName $ newMinion^.Model.minionName
            oldMinionAttr = ("oldMinion", oldMinionName)
            newMinionAttr = ("newMinion", newMinionName)
        tag 'Transformed [oldMinionAttr, newMinionAttr]
    MinionDied minion -> do
        minionName <- query $ showHandle minion
        let minionAttr = ("minion", minionName)
        tag 'MinionDied [minionAttr]
    EnactAttack attacker defender -> do
        attackerName <- query $ showHandle attacker
        defenderName <- query $ showHandle defender
        let attackerAttr = ("attacker", attackerName)
            defenderAttr = ("defender", defenderName)
        tag 'EnactAttack [attackerAttr, defenderAttr]
    GainsManaCrystal player mCrystalState -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
            varietyAttr = ("variety", maybe (nameBase 'Nothing) show mCrystalState)
        tag 'GainsManaCrystal [playerAttr, varietyAttr]
    ManaCrystalsRefill player amount -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
            amountAttr = ("amount", show amount)
        tag 'ManaCrystalsRefill [playerAttr, amountAttr]
    ManaCrystalsEmpty player amount -> do
        playerName <- query $ showHandle player
        let playerAttr = ("player", playerName)
            amountAttr = ("amount", show amount)
        tag 'ManaCrystalsEmpty [playerAttr, amountAttr]
    LostDivineShield minion -> do
        minionName <- query $ showHandle minion
        let minionAttr = ("minion", minionName)
        tag 'LostDivineShield [minionAttr]
    Silenced minion -> do
        minionName <- query $ showHandle minion
        let minionAttr = ("minion", minionName)
        tag 'Silenced [minionAttr]
    AttackFailed reason -> let
        reasonAttr = ("reason", show reason)
        in tag 'AttackFailed [reasonAttr]
    where
        query = runQuery snapshot
        tag name attrs = let
            name' = case nameBase name of
                (c : cs) -> toLower c : cs
                "" -> ""
            in verbosityGate name' $ openTag name' attrs >> closeTag name'


showHandle :: Handle a -> Hearth Console String
showHandle = mapHandle showSpellHandle showMinionHandle showPlayerHandle showCharacterHandle


showSpellHandle :: Handle Spell -> Hearth Console String
showSpellHandle h = view $ getSpell h.castSpell.Model.spellName.to showCardName


showMinionHandle :: Handle Minion -> Hearth Console String
showMinionHandle h = view $ getMinion h.boardMinion.Model.minionName.to showCardName


showPlayerHandle :: Handle Player -> Hearth Console String
showPlayerHandle h = view $ getPlayer h.playerHero.boardHero.heroName.to showHeroName


showCharacterHandle :: Handle Character -> Hearth Console String
showCharacterHandle = \case
    PlayerCharacter h -> showPlayerHandle h
    MinionCharacter h -> showMinionHandle h


showCardName :: CardName -> String
showCardName = \case
    BasicCardName name -> show name
    ClassicCardName name -> show name


showHeroPowerName :: HeroPowerName -> String
showHeroPowerName = \case
    BasicHeroPowerName name -> show name


showHeroName :: HeroName -> String
showHeroName = \case
    BasicHeroName name -> show name


handCardName' :: HandCard -> String
handCardName' = showCardName . handCardName


deckCardName' :: DeckCard -> String
deckCardName' = showCardName . deckCardName


promptError :: HearthError -> Console ()
promptError e = $logicError 'promptError $ show e


instance MonadPrompt HearthPrompt Console where
    prompt = \case
        PromptDebugEvent e -> debugEvent e
        PromptError e -> promptError e
        PromptGameEvent snapshot e -> gameEvent snapshot e
        PromptAction snapshot -> getAction snapshot
        PromptShuffle xs -> liftIO $ shuffleM xs
        PromptPickAtRandom p -> handlePromptPick p
        PromptPickTargeted p -> handlePromptPick p
        PromptMulligan _ xs -> return xs


handlePromptPick :: (MakePick s) => PromptPick s a -> Console (PickResult s a)
handlePromptPick = \case
    PickMinion snapshot xs -> pickMinion snapshot xs
    PickPlayer snapshot xs -> pickPlayer snapshot xs
    PickCharacter snapshot xs -> pickCharacter snapshot xs
    PickElect snapshot xs -> pickElect snapshot xs


class MakePick s where
    mkPick :: (Eq a) => (SignedInt -> Hearth Console (Maybe a)) -> GameSnapshot -> NonEmpty a -> Console (PickResult s a)
    pickElect :: GameSnapshot -> NonEmpty (Elect s) -> Console (PickResult s (Elect s))


instance MakePick AtRandom where
    mkPick _ _ = liftM AtRandomPick . pickRandom
    pickElect _ = liftM AtRandomPick . pickRandom


instance MakePick Targeted where
    mkPick fromSignedInt snapshot candidates = do
        view isAutoplay >>= \case
            True -> liftM TargetedPick $ pickRandom candidates
            False -> let
                abort = return AbortTargetedPick
                in view pendingTargets >>= \case
                    [] -> abort
                    pendingTarget : rest -> do
                        pendingTargets .= rest
                        mTarget <- runQuery snapshot $ fromSignedInt pendingTarget
                        case mTarget of
                            Nothing -> abort
                            Just target -> case target `elem` toList candidates of
                                True -> return $ TargetedPick target
                                False -> abort
    pickElect _ candidates = do
        view isAutoplay >>= \case
            True -> liftM TargetedPick $ pickRandom candidates
            False -> let
                abort = return AbortTargetedPick
                in view pendingTargets >>= \case
                    [] -> abort
                    pendingTarget : rest -> do
                        pendingTargets .= rest
                        let candidates' = toList candidates
                            mIndex = case pendingTarget of
                                SignedInt Positive n -> case 1 <= n && n <= length candidates' of
                                    True -> Just $ n - 1
                                    False -> Nothing
                                _ -> Nothing
                        case mIndex of
                            Nothing -> abort
                            Just index -> return $ TargetedPick $ candidates' !! index


pickMinion :: (MakePick s) => GameSnapshot -> NonEmpty MinionHandle -> Console (PickResult s MinionHandle)
pickMinion = mkPick fetchMinionHandle


pickPlayer :: (MakePick s) => GameSnapshot -> NonEmpty PlayerHandle -> Console (PickResult s PlayerHandle)
pickPlayer = mkPick fetchPlayerHandle


pickCharacter :: (MakePick s) => GameSnapshot -> NonEmpty CharacterHandle -> Console (PickResult s CharacterHandle)
pickCharacter = mkPick fetchCharacterHandle


enums :: (Enum a) => [a]
enums = enumFrom $ toEnum 0


data Conjunction = And | Or


itemize :: (Show a) => Conjunction -> [a] -> String
itemize conj = \case
    [] -> ""
    [x] -> show x
    [x, y] -> show x ++ " and " ++ show y
    [x, y, z] -> show x ++ ", " ++ show y ++ ", " ++ conjStr ++ " " ++ show z
    x : rest -> show x ++ ", " ++ itemize conj rest
    where
        conjStr = case conj of
            And -> "and"
            Or -> "or"


programHelp :: HelpDescription -> Console ()
programHelp (HelpDescription desc) = do
    runGame .= False
    liftIO $ do
        let desc' = "\n HearthShroud\n\n" ++ desc
        putStrLn desc'
        cursorUpLine $ 1 + length (lines desc')
        printBanner 75


consoleOptions :: Options Console () ()
consoleOptions = do
    addOption (kw ["-h", "--help"] `text` "Display this help text.")
        programHelp
    addOption (kw ["--verbosity"] `argText` "VERBOSITY" `text` ("One of: " ++ itemize Or (enums :: [Verbosity])))
        (logState.verbosity .=)
    addOption (kw "--seed" `argText` "INT" `text` "Sets the random number seed to INT.")
        ((gameSeed .=) . Just)


main :: IO ()
main = finally runTestGame $ do
    setSGR [SetColor Background Dull Black]
    setSGR [SetColor Foreground Dull White]


runTestGame :: IO ()
runTestGame = flip evalStateT st $ unConsole $ do
    args <- liftIO getArgs
    case runOptions consoleOptions args of
        Left (ParseFailed msg _ _) -> liftIO $ do
            putStrLn msg
            putStrLn $ getHelpDescription consoleOptions
        Right ms -> sequence_ ms >> view runGame >>= \case
            False -> return ()
            True -> do
                seed <- view gameSeed >>= \case
                    Nothing -> liftIO randomIO
                    Just seed -> return seed
                liftIO $ setStdGen $ mkStdGen seed
                let tag name attrs = openTag name attrs >> closeTag name
                tag "gameSeed" [("value", show seed)]
                _ <- runHearth (player1, player2)
                liftIO clearScreen
                window <- liftIO getWindowSize
                renewLogWindow window 0
                liftIO enterToContinue
    where
        st = ConsoleState {
            _gameSeed = Nothing,
            _runGame = True,
            _pendingTargets = [],
            _playedMinionIdx = Nothing,
            _isAutoplay = False,
            _logState = LogState {
                _loggedLines = [""],
                _totalLines = 1,
                _undisplayedLines = 1,
                _tagDepth = 0,
                _useShortTag = False,
                _verbosity = defaultVerbosity } }
        hero name power = Hero {
            _heroAttack = 0,
            _heroHealth = 30,
            _heroPower = power,
            _heroName = BasicHeroName name }
        cards = filter ((/= BasicCardName TheCoin) . deckCardName) Universe.cards
        deck1 = Deck cards
        deck2 = deck1
        player1 = PlayerData (hero Jaina fireblast) deck1
        player2 = PlayerData (hero Gul'dan lifeTap) deck2


fireblast :: HeroPower
fireblast = HeroPower {
    _heroPowerName = BasicHeroPowerName Fireblast,
    _heroPowerCost = ManaCost 2,
    _heroPowerEffect = \_ ->
        A $ Character [] $ \target ->
            Effect $ DealDamage target 1 }


lifeTap :: HeroPower
lifeTap = HeroPower {
    _heroPowerName = BasicHeroPowerName LifeTap,
    _heroPowerCost = ManaCost 2,
    _heroPowerEffect = \you -> 
        Effect $ Sequence [
            DrawCards you 1,
            DealDamage (PlayerCharacter you) 2 ]}


getWindowSize :: IO (Window Int)
getWindowSize = Window.size >>= \case
    Just w -> return $ w { Window.width = Window.width w - 1 }
    Nothing -> $runtimeError 'getWindowSize "Could not get window size."


renewDisplay :: Hearth Console ()
renewDisplay = do
    ps <- getPlayerHandles
    window <- liftIO getWindowSize
    deepestPlayer <- do
        liftIO $ do
            clearScreen
            setSGR [SetColor Foreground Dull White]
        foldM (\n -> liftM (max n) . printPlayer window) 0 ps
    lift $ do
        renewLogWindow window $ deepestPlayer + 1


presentPrompt :: (MonadIO m) => String -> ([String] -> m a) -> m a
presentPrompt promptMessage responseParser = do
    response <- liftM (map toLower) $ liftIO $ do
        setSGR [SetColor Foreground Dull White]
        putStrLn promptMessage
        liftIO $ do
            cursorUpLine $ 1 + length (lines promptMessage)
            printBanner 75
        putStrLn ""
        putStr "> "
        getLine
    let tokenizeResponse = words
            . concatMap (\case
                '+' -> " +"
                '-' -> " -"
                '.' -> "?"
                c -> [c] )
            . map toUpper
            . filter (not . isSpace)
    responseParser $ case tokenizeResponse response of
        [] -> [""]
        args -> args


parseActionResponse :: [String] -> Hearth Console Action
parseActionResponse response = do
    lift $ do
        isAutoplay .= False
        playedMinionIdx .= Nothing
    case runOptions actionOptions response of
        Left (ParseFailed err _ _) -> do
            liftIO $ putStrLn err
            process $ ComplainRetryAction "Could not parse command."
        Right ms -> case ms of
            [m] -> m >>= process
            _ -> process $ ComplainRetryAction "Please only provide one command."
    where
        process = \case
            QuitAction -> liftM ActionPlayerConceded getActivePlayerHandle
            GameAction action -> return action
            QuietRetryAction -> getAction'
            ComplainRetryAction reason -> do
                liftIO $ do
                    putStrLn reason
                    putStrLn ""
                    enterToContinue
                process QuietRetryAction


data ConsoleAction :: * where
    QuitAction :: ConsoleAction
    GameAction :: Action -> ConsoleAction
    QuietRetryAction :: ConsoleAction
    ComplainRetryAction :: String -> ConsoleAction


actionOptions :: Options (Hearth Console) ConsoleAction ()
actionOptions = do
    addOption (kw "" `argText` "" `text` "Autoplay.")
        autoplayAction
    addOption (kw "Q" `text` "Concede and quit.")
        quitAction
    addOption (kw "0" `text` "Ends the active player's turn.")
        endTurnAction
    addOption (kw "1" `argText` "MINION POS TARGETS*" `text` "Plays MINION from your hand to board POS.")
        nonParseable
    addOption (kw "1" `argText` "SPELL TARGETS*" `text` "Plays SPELL from your hand.")
        playCardAction
    addOption (kw "2" `argText` "ATTACKER DEFENDER" `text` "Attack DEFENDER with ATTACKER.")
        attackAction
    addOption (kw "3" `argText` "TARGETS*" `text` "Use hero power.")
        useHeroPowerAction
    addOption (kw "?" `argText` "CARD" `text` "Read CARD from a player's hand.")
        readCardInHandAction
    addOption (kw "?" `text` "Display detailed help text.")
        helpAction
    addOption (kw "." `text` "An alias for (?).")
        nonParseable


enterToContinue :: IO ()
enterToContinue = do
    setSGR [SetColor Foreground Dull White]
    putStrLn "*** PRESS ENTER TO CONTINUE ***"
    _ <- getLine
    return ()


quitAction :: Hearth Console ConsoleAction
quitAction = return QuitAction


rawBanner :: [String]
rawBanner = [
      ""
    , "    _____________________"
    , "  +/7777777777|77777777772+"
    , "  |1*`  2   ( . )   /  `*1|"
    , "  |1` 2   (   ^   )   / `1|"
    , "  |1  (Hearth{@}Shroud)  1|"
    , "  |1, /    (  v  )    2 ,1|"
    , "  |1*,  /   ( ' )   2  ,*1|"
    , "  ++7777777777|7777777777++"
    , "   2+-------------------+/"
    , "" ]


sgrBanner :: [SGRString]
sgrBanner = flip map rawBanner $ concatMap $ \case
    '2' -> f '\\' Dull Green
    '/' -> f '/' Dull Green
    '1' -> f '|' Vivid Red
    '|' -> f '|' Vivid Yellow
    '7' -> f '-' Vivid Red
    '-' -> f '-' Vivid Yellow
    '_' -> f '_' Vivid Yellow
    '+' -> f '+' Vivid Yellow
    '*' -> f '*' Vivid Magenta
    '.' -> f '.' Vivid Green
    '\''-> f '\'' Vivid Green
    '(' -> f '(' Vivid Green
    ')' -> f ')' Vivid Green
    '@' -> sgr [SetColor Background Vivid Blue] ++ f '@' Dull Black ++ sgr [SetColor Background Dull Black]
    '{' -> f '(' Vivid Black
    '}' -> f ')' Vivid Black
    '^' -> f '^' Dull Cyan
    'v' -> f 'v' Dull Cyan
    c -> f c Dull White
    where
        f ch intensity color = sgrColor (intensity, color) ++ [Right ch]


printBanner :: Int -> IO ()
printBanner columnOffset = do
    setSGR [SetColor Foreground Vivid Black]
    forM_ sgrBanner $ \str -> do
        setCursorColumn columnOffset
        putSGRString $ str ++ [Right '\n']
    setSGR [SetColor Foreground Dull White]


helpAction :: Hearth Console ConsoleAction
helpAction = do
    liftIO $ do
        setCursorPosition 1 0
        clearScreen
        putStrLn formattedActionOptions
        cursorUpLine $ 1 + length (lines formattedActionOptions)
        printBanner 75
        putStrLn ""
        putStrLn "Usage:"
        putStrLn "> COMMAND+ARG1+ARG2+ARG3+..."
        putStrLn ""
        putStrLn "(+) and (-) are used to delimit arguments and affect their following arguments' signs."
        putStrLn "Positive arguments denote friendly or neutral choices. Negative arguments denote enemy choices."
        putStrLn "Players are denoted by the number 0."
        putStrLn ""
        putStrLn "- Example: Summon hand minion 4 to board position 3."
        putStrLn "> 1+4+3"
        putStrLn ""
        putStrLn "- Example: Attack with minion 1 against opponent."
        putStrLn "> 2+1-0"
        putStrLn ""
        putStrLn "- Example: Play Fireball (hand spell 3) against opposing hero."
        putStrLn "> 1+3-0"
        putStrLn ""
        putStrLn "- Example: Play Fireball (hand spell 3) against own hero."
        putStrLn "> 1+3+0"
        putStrLn ""
        enterToContinue
    return QuietRetryAction


cmpKeyword :: Keyword -> Keyword -> Ordering
cmpKeyword =  comparing $ \k -> let
    name = concat $ kwNames k
    in case name of
        "" -> -1
        [c] -> case c of
            '?' -> 50 + case kwArgText k of
                "" -> 1
                _ -> 0
            '.' -> 999
            _ -> case isDigit c of
                True -> 30 + ord c - ord '0'
                False -> case isAlpha c of
                    True -> ord c - ord 'A'
                    False -> -666
        _ -> -666


formattedActionOptions :: String
formattedActionOptions = let
    name k = case concat $ kwNames k of
        "" -> " "
        n -> case kwArgText k of
            [] -> n
            _ -> n ++ " "
    ks = sortBy cmpKeyword $ getKeywords actionOptions
    kwLen k = length $ name k ++ kwArgText k
    maxKwLen = maximum $ map kwLen ks
    format k = let
        nameArgs = name k ++ kwArgText k
        pad = replicate (maxKwLen - kwLen k) '-'
        in "-- " ++ nameArgs ++ " --" ++ pad ++ " " ++ kwText k
    in intercalate "\n" $ map format ks


class PickRandom l a | l -> a where
    pickRandom :: (MonadIO m) => l -> m a


instance PickRandom [a] (Maybe a) where
    pickRandom = liftIO . liftM listToMaybe . shuffleM


instance PickRandom (NonEmpty a) a where
    pickRandom (NonEmpty x xs) = pickRandom (x : xs) >>= \case
        Just y -> return y
        Nothing -> $logicError 'pickRandom "Can't pick from (NonEmpty a)?"


autoplayAction :: Hearth Console ConsoleAction
autoplayAction = lift (isAutoplay .= True) >> liftIO (shuffleM activities) >>= decideAction
    where
        decideAction = \case
            [] -> endTurnAction
            m : ms -> m >>= \case
                Nothing -> decideAction ms
                Just action -> action
        activities = [
            tryPlayMinion,
            tryPlaySpell,
            tryAttackPlayerPlayer,
            tryAttackPlayerMinion,
            tryAttackMinionPlayer,
            tryHeroPower,
            tryAttackMinionMinion ]
        tryPlayMinion = do
            handle <- getActivePlayerHandle
            cards <- view $ getPlayer handle.playerHand.handCards
            maxPos <- view $ getPlayer handle.playerMinions.to (BoardPos . length)
            let positions = [BoardPos 0 .. maxPos]
            pos <- liftM head $ liftIO $ shuffleM positions
            allowedCards <- flip filterM (reverse cards) $ \card -> local id (playMinion handle card pos) >>= \case
                Failure {} -> return False
                Success -> return True
            pickRandom allowedCards >>= return . \case
                Nothing -> Nothing
                Just card -> Just $ return $ GameAction $ ActionPlayMinion card pos
        tryHeroPower = do
                return $ Just $ return $ GameAction ActionHeroPower
        tryPlaySpell = do
            handle <- getActivePlayerHandle
            cards <- view $ getPlayer handle.playerHand.handCards
            allowedCards <- flip filterM (reverse cards) $ \card -> local id (playSpell handle card) >>= \case
                Failure {} -> return False
                Success -> return True
            pickRandom allowedCards >>= return . \case
                Nothing -> Nothing
                Just card -> Just $ return $ GameAction $ ActionPlaySpell card
        tryAttack predicate = do
            activeHandle <- getActivePlayerHandle
            activeMinions' <- view $ getPlayer activeHandle.playerMinions
            nonActiveHandle <- getNonActivePlayerHandle
            nonActiveMinions' <- view $ getPlayer nonActiveHandle.playerMinions
            let activeMinions = map characterHandle activeMinions'
                nonActiveMinions = map characterHandle nonActiveMinions'
                pairs = filter predicate $ (PlayerCharacter activeHandle, PlayerCharacter nonActiveHandle)
                     : [(a, na) | a <- activeMinions, na <- nonActiveMinions]
                    ++ [(PlayerCharacter activeHandle, na) | na <- nonActiveMinions]
                    ++ [(a, PlayerCharacter nonActiveHandle) | a <- activeMinions]
            allowedPairs <- flip filterM pairs $ \(activeChar, nonActiveChar) -> do
                local id $ enactAttack activeChar nonActiveChar >>= \case
                    Failure {} -> return False
                    Success -> return True
            pickRandom allowedPairs >>= return . \case
                Nothing -> Nothing
                Just (attacker, defender) -> Just $ return $ GameAction $ ActionAttack attacker defender
        tryAttackPlayerPlayer = tryAttack $ \case
            (PlayerCharacter _, PlayerCharacter _) -> True
            _ -> False
        tryAttackPlayerMinion = tryAttack $ \case
            (PlayerCharacter _, MinionCharacter _) -> True
            _ -> False
        tryAttackMinionPlayer = tryAttack $ \case
            (MinionCharacter _, PlayerCharacter _) -> True
            _ -> False
        tryAttackMinionMinion = tryAttack $ \case
            (MinionCharacter _, MinionCharacter _) -> True
            _ -> False


endTurnAction :: Hearth Console ConsoleAction
endTurnAction = return $ GameAction ActionEndTurn


lookupIndex :: [a] -> Int -> Maybe a
lookupIndex (x:xs) n = case n == 0 of
    True -> Just x
    False -> lookupIndex xs (n - 1)
lookupIndex [] _ = Nothing


readCardInHandAction :: SignedInt -> Hearth Console ConsoleAction
readCardInHandAction (SignedInt sign handIdx) = do
    handle <- case sign of
        Positive -> getActivePlayerHandle
        Negative -> getNonActivePlayerHandle
    cards <- view $ getPlayer handle.playerHand.handCards
    let mCard = lookupIndex cards $ length cards - handIdx
    case mCard of
        Nothing -> return $ ComplainRetryAction "Invalid hand card index"
        Just card -> do
            liftIO $ do
                let cardStr = showCard card
                setCursorPosition 2 0
                clearScreen
                printBanner 75
                cursorUpLine 10
                putStrLn "  __________________ "
                putStrLn " /                  \\"
                putStrLn " | CARD INFORMATION |"
                putStrLn " \\__________________/"
                putStrLn ""
                forM_ (lines cardStr) $ \ln -> putStrLn $ "  " ++ ln
                putStrLn ""
                enterToContinue
                return QuietRetryAction


fetchPlayerHandle :: SignedInt -> Hearth Console (Maybe PlayerHandle)
fetchPlayerHandle (SignedInt sign idx) = case idx of
    0 -> liftM Just $ case sign of
        Positive -> getActivePlayerHandle
        Negative -> getNonActivePlayerHandle
    _ -> return Nothing


fetchMinionHandle :: SignedInt -> Hearth Console (Maybe MinionHandle)
fetchMinionHandle (SignedInt sign idx) = case idx of
    0 -> return Nothing
    _ -> do
        mStradleIdx <- lift $ view playedMinionIdx
        p <- case sign of
            Positive -> getActivePlayerHandle
            Negative -> getNonActivePlayerHandle
        ms <- view $ getPlayer p.playerMinions
        return $ lookupIndex (map _boardMinionHandle ms) $ idx - 1 + case sign of
            Negative -> 0
            Positive -> case mStradleIdx of
                Nothing -> 0
                Just stradleIdx -> case idx < stradleIdx of
                    True -> 0
                    False -> 1


fetchCharacterHandle :: SignedInt -> Hearth Console (Maybe CharacterHandle)
fetchCharacterHandle idx = fetchPlayerHandle idx >>= \case
    Just handle -> return $ Just $ PlayerCharacter handle
    Nothing -> liftM (liftM MinionCharacter) $ fetchMinionHandle idx


attackAction :: SignedInt -> SignedInt -> Hearth Console ConsoleAction
attackAction attackerIdx defenderIdx = do
    mAttacker <- fetchCharacterHandle attackerIdx
    mDefender <- fetchCharacterHandle defenderIdx
    case mAttacker of
        Nothing -> return $ ComplainRetryAction "Invalid attacker index."
        Just attacker -> case mDefender of
            Nothing -> return $ ComplainRetryAction "Invalid defender index."
            Just defender -> return $ GameAction $ ActionAttack attacker defender


useHeroPowerAction :: List SignedInt -> Hearth Console ConsoleAction
useHeroPowerAction (List targets) = localQuiet $ do
    lift $ pendingTargets .= targets
    local id $ enactAction ActionHeroPower >>= \case
        Right EndTurn -> $logicError 'useHeroPowerAction "This should never get hit."
        Left result -> case result of
            Failure msg -> return $ ComplainRetryAction msg
            Success -> lift (view pendingTargets) >>= \case
                (_ : _) -> return $ ComplainRetryAction "Too many targets."
                [] -> do
                    lift $ pendingTargets .= targets
                    return $ GameAction ActionHeroPower


playCardAction :: List SignedInt -> Hearth Console ConsoleAction
playCardAction = let

    goMinion :: SignedInt -> HandCard -> Hearth Console ConsoleAction
    goMinion (SignedInt Positive boardIdx) card = do
        handle <- getActivePlayerHandle
        boardLen <- view $ getPlayer handle.playerMinions.to length
        lift $ playedMinionIdx .= Just boardIdx
        case 0 < boardIdx && boardIdx <= boardLen + 1 of
            False -> return $ ComplainRetryAction "Invalid board index: Out of bounds."
            True -> return $ GameAction $ ActionPlayMinion card $ BoardPos $ boardIdx - 1
    goMinion _ _ = return $ ComplainRetryAction "Invalid board index: Must be positive."

    goSpell :: HandCard -> Hearth Console ConsoleAction
    goSpell card = return $ GameAction $ ActionPlaySpell card

    go :: Int -> [SignedInt] -> Hearth Console ConsoleAction
    go handIdx args = do
        handle <- getActivePlayerHandle
        cards <- view $ getPlayer handle.playerHand.handCards
        let mCard = lookupIndex cards $ length cards - handIdx
        case mCard of
            Nothing -> return $ ComplainRetryAction "Invalid hand card index."
            Just card -> case card of
                HandCardSpell _ -> goSpell card >>= go' args
                HandCardMinion _ -> case args of
                    boardPos : rest -> goMinion boardPos card >>= go' rest
                    [] -> return $ ComplainRetryAction "Playing a minion requires a board index."

    go' :: [SignedInt] -> ConsoleAction -> Hearth Console ConsoleAction
    go' targets = \case
        GameAction action -> do
            lift $ pendingTargets .= targets
            result <- local id $ localQuiet $ do
                result <- enactAction action >>= return . \case
                    Right EndTurn -> $logicError 'playCardAction "This should never get hit."
                    Left result -> result
                return result
            case result of
                Success -> lift (view pendingTargets) >>= \case
                    [] -> do
                        lift $ pendingTargets .= targets
                        return $ GameAction action
                    _ -> return $ ComplainRetryAction "Too many targets."
                Failure msg -> do
                    liftIO $ print targets
                    return $ ComplainRetryAction msg
        action -> return action
    in \case
        List (SignedInt Positive handIdx : args) -> go handIdx args
        _ -> return $ ComplainRetryAction "Hand card index must be positive when playing a card."


getAction :: GameSnapshot -> Console Action
getAction snapshot = do
    let name = showName 'getAction
    verbosityGate name $ openTag name []
    action <- localQuiet $ runQuery snapshot getAction'
    logState.undisplayedLines .= 0
    verbosityGate name $ closeTag name
    return action
    where
        showName = (':' :) . nameBase


getAction' :: Hearth Console Action
getAction' = do
    renewDisplay
    presentPrompt formattedActionOptions parseActionResponse


viewLogLineInfo :: Console (Int,  Int, [String])
viewLogLineInfo = zoom logState $ do
    tl <- view totalLines
    ul <- view undisplayedLines
    strs <- view loggedLines
    return $ case strs of
        "" : rest -> (tl - 1, ul, rest)
        _ -> (tl, ul, strs)


renewLogWindow :: Window Int -> Int -> Console ()
renewLogWindow window row = do
    let displayCount = Window.height window - 20 - row
    (totalCount, newCount, log) <- viewLogLineInfo
    let (newLines, oldLines) = id
            . splitAt (if totalCount < displayCount then min displayCount newCount + displayCount - totalCount else newCount)
            . zip (iterate pred $ max displayCount totalCount)
            . (replicate (displayCount - totalCount) "" ++)
            . take displayCount
            $ log
        lineNoLen = length $ show totalCount
        padWith c str = replicate (lineNoLen - length str) c ++ str
        putWithLineNo debugConfig gameConfig (lineNo, str) = do
            let config = case isDebug str of
                    True -> debugConfig
                    False -> gameConfig
                (intensity, color) = config
                lineNoStr = case totalCount < displayCount && null str of
                    True -> reverse $ padWith ' ' "~"
                    False -> padWith '0' $ show lineNo
            setSGR [SetColor Background Dull Blue, SetColor Foreground Vivid Black ]
            putStr $ lineNoStr
            setSGR [SetColor Background Dull Black]
            setSGR [SetColor Foreground intensity color]
            putStrLn $ " " ++ str ++ case reverse str of
                "" -> ""
                '>' : _ -> ""
                _ -> ">"
    liftIO $ do
        setSGR [SetColor Foreground (fst borderColor) (snd borderColor)]
        setCursorPosition row 0
        putStrLn $ replicate (Window.width window) '-'
        mapM_ (putWithLineNo oldDebugColor oldGameColor) $ reverse oldLines
        mapM_ (putWithLineNo newDebugColor newGameColor) $ reverse newLines
        setSGR [SetColor Foreground (fst borderColor) (snd borderColor)]
        putStrLn $ replicate (Window.width window) '-'
        putStrLn ""
    where
        isDebug s = any (`isInfixOf` s) ["<:", "</:"]
        borderColor = (Dull, Cyan)
        oldDebugColor = (Dull, Magenta)
        oldGameColor = (Vivid, Magenta)
        newDebugColor = (Dull, Cyan)
        newGameColor = (Dull, Green)


printPlayer :: Window Int -> PlayerHandle -> Hearth Console Int
printPlayer window pHandle = do
    player <- view $ getPlayer pHandle
    liftIO $ setSGR [SetColor Foreground Vivid Green]
    isActive <- liftM (pHandle ==) getActivePlayerHandle
    playerName <- showHandle pHandle
    let playerNameCol = fromString playerName ++ case isActive of
            True -> sgrColor (Dull, White) ++ fromString "*" ++ sgrColor (Dull, Cyan)
            False -> fromString ""
        (wx, wy, wz) = (15, 30, 30) :: (Int, Int, Int)
        width = Window.width window
        (deckLoc, handLoc, minionsLoc) = case pHandle of
                PlayerHandle n -> case n of
                    0 -> (0, wx, wx + wy)
                    1 -> (width - wx, width - wx - wy, width - wx - wy - wz)
                    _ -> $logicError 'printPlayer "xxx"
    playerCol <- playerColumn player
    handCol <- handColumn $ player^.playerHand
    boardMinionsCol <- boardMinionsColumn $ player^.playerMinions
    liftIO $ do
        n0 <- printColumn True (take (wx - 1) playerNameCol) deckLoc playerCol
        n1 <- printColumn True (fromString "HAND") handLoc handCol
        n2 <- printColumn False (fromString "   MINIONS") minionsLoc boardMinionsCol
        return $ maximum [n0, n1, n2]


printColumn :: Bool -> SGRString -> Int -> [SGRString] -> IO Int
printColumn extraLine label column strs = do
    let label' = filter (/= '*') $ rights label
        strs' = [
            label,
            fromString $ replicate (length $ takeWhile isSpace label') ' ' ++ replicate (length $ dropWhile isSpace label') '-'
            ] ++ (if extraLine then [fromString ""] else []) ++ strs
    zipWithM_ f [0..] strs'
    return $ length strs'
    where
        f row str = do
            setSGR [SetColor Foreground Dull Cyan]
            setCursorPosition row column
            putSGRString str


putSGRString :: SGRString -> IO ()
putSGRString = mapM_ $ \case
    Left s -> setSGR [s]
    Right c -> putChar c

















