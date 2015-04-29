{-# LANGUAGE ConstraintKinds #-}
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


module Hearth.Client.Console (
    main
) where


--------------------------------------------------------------------------------


import Control.Applicative
import Control.Error
import Control.Exception
import Control.Lens
import Control.Lens.Helper
import Control.Lens.Internal.Zoom (Zoomed, Focusing)
import Control.Monad.Loops
import Control.Monad.Prompt
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.State.Local
import Data.Char
import Data.Data
import Data.Generics.Uniplate.Data
import Data.List
import Data.NonEmpty
import Hearth.Action
import Hearth.Cards
import Hearth.Client.Console.BoardMinionsColumn
import Hearth.Client.Console.HandColumn
import Hearth.Client.Console.PlayerColumn
import Hearth.DebugEvent
import Hearth.Engine
import Hearth.GameEvent
import Hearth.Model
import Hearth.Names
import Hearth.Prompt
import Language.Haskell.TH.Syntax (nameBase)
import System.Console.ANSI
import System.Console.Terminal.Size (Window)
import System.Console.Terminal.Size as Window


--------------------------------------------------------------------------------


data LogState = LogState {
    _loggedLines :: [String],
    _totalLines :: !Int,
    _undisplayedLines :: !Int,
    _callDepth :: !Int,
    _useShortTag :: !Bool,
    _quiet :: !Bool
} deriving (Show, Eq, Ord)
makeLenses ''LogState


data ConsoleState = ConsoleState {
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


unlessM :: (Monad m) => m Bool -> m () -> m ()
unlessM c m = do
    c >>= \case
        False -> m
        True -> return ()


isQuiet :: Console Bool
isQuiet = view $ logState.quiet


localQuiet :: Console a -> Console a
localQuiet m = do
    q <- view $ logState.quiet
    logState.quiet .= True
    x <- m
    logState.quiet .= q
    return x


newLogLine :: Console ()
newLogLine = zoom logState $ do
    totalLines += 1
    undisplayedLines += 1
    loggedLines %= ("" :)


appendLogLine :: String -> Console ()
appendLogLine str = logState.loggedLines %= \case
    s : ss -> (s ++ str) : ss
    [] -> $logicError 'appendLogLine


logIndentation :: Console String
logIndentation = do
    n <- view $ logState.callDepth
    return $ concat $ replicate n "    "


debugEvent :: DebugEvent -> Console ()
debugEvent e = unlessM isQuiet $ case e of
    FunctionEntered name -> do
        logState.useShortTag >>=. \case
            True -> do
                appendLogLine ">"
                newLogLine
            False -> return ()
        lead <- logIndentation
        logState.callDepth += 1
        logState.useShortTag .= True
        appendLogLine $ lead ++ "<:" ++ (showName name)
    FunctionExited name -> do
        logState.callDepth -= 1
        logState.useShortTag >>=. \case
            True -> do
                appendLogLine "/>"
                newLogLine
            False -> do
                lead <- logIndentation
                appendLogLine $ lead ++ "</:" ++ (showName name) ++ ">"
                newLogLine
        logState.useShortTag .= False
    where
        showName = nameBase


gameEvent :: GameEvent -> Console ()
gameEvent e = unlessM isQuiet $ do
    logState.useShortTag >>=. \case
        True -> do
            appendLogLine "/>"
            newLogLine
        False -> return ()
    logState.useShortTag .= False
    txt <- return $ case e of
        CardDrawn (PlayerHandle who) (mCard) (Deck deck) -> let
            cardAttr = case mCard of
                Nothing -> ""
                Just card -> " card=" ++ quote (simpleName card)
            in "<cardDrawn"
                ++ " handle=" ++ quote who
                ++ cardAttr
                ++ " deck=" ++ quote (length deck)
                ++ " />"
        PlayedCard (PlayerHandle who) card result -> case result of
            Failure -> ""
            Success -> "<playedCard"
                ++ " handle=" ++ quote who
                ++ " card=" ++ quote (simpleName card)
                ++ " />"
        HeroTakesDamage (PlayerHandle who) (Health oldHealth) (Damage damage) -> let
            newHealth = oldHealth - damage
            in "<heroTakesDamage"
                ++ " handle=" ++ quote who
                ++ " old=" ++ quote oldHealth
                ++ " new=" ++ quote newHealth
                ++ " dmg=" ++ quote damage
                ++ " />"
        GainsManaCrystal (PlayerHandle who) mCrystalState -> let
            stateAttr = case mCrystalState of
                Nothing -> "none"
                Just CrystalFull -> "full"
                Just CrystalEmpty -> "empty"
            in "<gainsManaCrystal"
                ++ " handle=" ++ quote who
                ++ " crystal=" ++ show stateAttr
                ++ " />"
        ManaCrystalsRefill (PlayerHandle who) amount -> let
            in "<manaCrystalsRefill"
                ++ " handle=" ++ quote who
                ++ " amount=" ++ quote amount
                ++ "/>"
        ManaCrystalsEmpty (PlayerHandle who) amount -> let
            in "<manaCrystalsEmpty"
                ++ " handle=" ++ quote who
                ++ " amount=" ++ quote amount
                ++ "/>"
    case null txt of
        True -> return ()
        False -> do
            lead <- logIndentation
            appendLogLine $ lead ++ txt
            newLogLine
    where
        quote = show . show


simpleName :: (Data a) => a -> BasicCardName
simpleName card = case universeBi card of
    [name] -> name
    _ -> $logicError 'simpleName


instance MonadPrompt HearthPrompt Console where
    prompt = \case
        PromptDebugEvent e -> debugEvent e
        PromptGameEvent e -> gameEvent e
        PromptAction snapshot -> getAction snapshot
        PromptShuffle xs -> return xs
        PromptPickRandom (NonEmpty x _) -> return x
        PromptMulligan _ xs -> return xs


main :: IO ()
main = do
    result <- finally runTestGame $ do
        setSGR [SetColor Foreground Dull White]
        clearScreen
        setCursorPosition 0 0
    print result


runTestGame :: IO GameResult
runTestGame = flip evalStateT st $ unConsole $ runHearth (player1, player2)
    where
        st = ConsoleState {
            _logState = LogState {
                _loggedLines = [""],
                _totalLines = 1,
                _undisplayedLines = 1,
                _callDepth = 0,
                _useShortTag = False,
                _quiet = False } }
        power = HeroPower {
            _heroPowerCost = ManaCost 0,
            _heroPowerEffects = [] }
        hero name = Hero {
            _heroAttack = 0,
            _heroHealth = 30,
            _heroPower = power,
            _heroName = BasicHeroName name }
        deck1 = Deck $ take 30 $ cycle cardUniverse
        deck2 = Deck $ take 30 $ cycle $ reverse cardUniverse
        player1 = PlayerData (hero Thrall) deck1
        player2 = PlayerData (hero Rexxar) deck2


data Who = Alice | Bob
    deriving (Show, Eq, Ord)


getWindowSize :: IO (Window Int)
getWindowSize = Window.size >>= \case
    Nothing -> $runtimeError 'getWindowSize "Could not get window size."
    Just w -> return $ w { width = Window.width w - 1 }


renewDisplay :: Hearth Console ()
renewDisplay = do
    ps <- mapM (view . getPlayer) =<< getPlayerHandles
    window <- liftIO getWindowSize
    deepestPlayer <- liftIO $ do
        clearScreen
        setSGR [SetColor Foreground Dull White]
        foldM (\n -> liftM (max n) . uncurry (printPlayer window)) 0 (zip ps [Alice, Bob])
    lift $ do
        renewLogWindow window $ deepestPlayer + 1


data ConsoleAction :: * -> * where
    QuitAction :: ConsoleAction ()
    GameAction :: ConsoleAction Action


data PromptInfo m a = PromptInfo {
    _key :: String,
    _desc :: String,
    _action :: m (Maybe a)
}


presentPrompt :: (MonadIO m) => m a -> [PromptInfo m a] -> m a
presentPrompt retry promptInfos = do
    response <- liftM (map toLower) $ liftIO $ do
        setSGR [SetColor Foreground Dull White]
        forM_ promptInfos $ \pi -> putStrLn $ "* " ++ _key pi ++ _desc pi
        putStrLn ""
        putStr "> "
        getLine
    let mPromptInfo = flip find promptInfos $ \pi -> map toLower (_key pi) `isPrefixOf` response
    case mPromptInfo of
        Nothing -> retry
        Just pi -> _action pi >>= \case
            Nothing -> retry
            Just result -> return result


actionPrompts :: [PromptInfo (Hearth Console) Action]
actionPrompts = [
    PromptInfo "E" " - End Turn" $ return $ Just ActionEndTurn,
    PromptInfo "P" " - Play card" playCardAction ]


playCardAction :: Hearth Console (Maybe Action)
playCardAction = do
    handle <- getActivePlayerHandle
    cards <- view $ getPlayer handle.playerHand.handCards
    mCard <- flip firstM cards $ \card -> playCard handle card >>= \case
        Failure -> return False
        Success -> return True
    case mCard of
        Nothing -> return Nothing
        Just card -> return $ Just $ ActionPlayCard card


getAction :: GameSnapshot -> Console Action
getAction snapshot = do
    let go = do
            renewDisplay
            presentPrompt go actionPrompts
    action <- localQuiet $ runQuery snapshot go
    logState.undisplayedLines .= 0
    return action


renewLogWindow :: Window Int -> Int -> Console ()
renewLogWindow window row = do
    let displayCount = Window.height window - 20 - row
    totalCount <- view $ logState.totalLines
    let lineNoLen = length $ show totalCount
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
            putStrLn $ " " ++ str
    newCount <- view $ logState.undisplayedLines
    (newLines, oldLines) <- view $ logState.loggedLines.to (id
        . splitAt (if totalCount < displayCount then min displayCount newCount + displayCount - totalCount else newCount)
        . zip (iterate pred $ max displayCount totalCount)
        . (replicate (displayCount - totalCount) "" ++)
        . take displayCount)
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
        isDebug str = "<:" `isInfixOf` str || "</:" `isInfixOf` str
        borderColor = (Dull, Cyan)
        oldDebugColor = (Dull, Magenta)
        oldGameColor = (Vivid, Magenta)
        newDebugColor = (Dull, Cyan)
        newGameColor = (Dull, Green)


printPlayer :: Window Int -> Player -> Who -> IO Int
printPlayer window p who = do
    setSGR [SetColor Foreground Vivid Green]
    let playerName = map toUpper $ show who
        player = playerColumn p
        hand = handColumn $ p^.playerHand
        boardMinions = boardMinionsColumn $ p^.playerMinions
        (deckLoc, handLoc, minionsLoc) = let
            (x, y, z) = (0, 25, 50)
            width = Window.width window - 10
            in case who of
                Alice -> (x, y, z)
                Bob -> (width - x, width - y, width - z)
    n0 <- printColumn playerName deckLoc player
    n1 <- printColumn "HAND" handLoc hand
    n2 <- printColumn "MINIONS" minionsLoc boardMinions
    return $ maximum [n0, n1, n2]


printColumn :: String -> Int -> [String] -> IO Int
printColumn label column strs = do
    let strs' = [label, replicate (length label) '-', ""] ++ strs
    zipWithM_ f [0..] strs'
    return $ length strs'
    where
        f row str = do
            setCursorPosition row column
            putStr str



















