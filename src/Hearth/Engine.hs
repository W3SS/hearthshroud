{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}


module Hearth.Engine where


--------------------------------------------------------------------------------


import Control.Applicative
import Control.Error
import Control.Lens
import Control.Lens.Helper
import Control.Lens.Internal.Zoom (Zoomed, Focusing)
import Control.Monad.Loops
import Control.Monad.Prompt
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.State.Local
import Data.Data
import Data.Function
import Data.List
import Data.List.Ordered
import Data.Maybe
import qualified Data.NonEmpty as NonEmpty
import Hearth.Action
import Hearth.DebugEvent
import Hearth.DeckToHand
import Hearth.GameEvent
import Hearth.HandToDeck
import Hearth.Model
import Hearth.Prompt
import Language.Haskell.TH.Syntax (Name)


--------------------------------------------------------------------------------


type Pair a = (a, a)


newtype Hearth' st m a = Hearth {
    unHearth :: StateT st m a
} deriving (Functor, Applicative, Monad, MonadState st, MonadIO, MonadTrans)


instance (Monad m) => MonadReader st (Hearth' st m) where
    ask = get
    local = stateLocal


type Hearth = Hearth' GameState
type HearthMonad m = MonadPrompt HearthPrompt m


type instance Zoomed (Hearth' st m) = Focusing m


instance Monad m => Zoom (Hearth' st m) (Hearth' st' m) st st' where
    zoom l = Hearth . zoom l . unHearth


instance (HearthMonad m) => MonadPrompt HearthPrompt (Hearth' st m) where
    prompt = lift . prompt


class LogCall a where
    logCall :: Name -> a -> a


instance (HearthMonad m) => LogCall (Hearth' st m a) where
    logCall funcName m = do
        prompt $ PromptDebugEvent $ FunctionEntered funcName
        x <- m
        prompt $ PromptDebugEvent $ FunctionExited funcName
        return x


instance (HearthMonad m) => LogCall (a -> Hearth' st m b) where
    logCall msg f = logCall msg . f


instance (HearthMonad m) => LogCall (a -> b -> Hearth' st m c) where
    logCall msg f = logCall msg . f


data PlayerData = PlayerData Hero Deck
    deriving (Show, Typeable)


guardedPrompt :: (MonadPrompt p m) => p a -> (a -> Bool) -> m a
guardedPrompt p f = prompt p >>= \x -> case f x of
    True -> return x
    False -> guardedPrompt p f


isSubsetOf :: (Ord a) => [a] -> [a] -> Bool
isSubsetOf = subset `on` sort


runQuery :: (HearthMonad m) => GameSnapshot -> Hearth m a -> m a
runQuery snapshot query = evalStateT (unHearth query') $ snapshot^.snapshotGameState
    where
        query' = logCall 'runQuery query


runHearth :: (HearthMonad m) => Pair PlayerData -> m GameResult
runHearth = evalStateT (unHearth runGame) . mkGameState


mkGameState :: Pair PlayerData -> GameState
mkGameState (p1, p2) = let
    ps = [p1, p2]
    in GameState {
        _gameTurn = Turn 1,
        _gameHandleSeed = RawHandle $ length ps,
        _gamePlayerTurnOrder = [],
        _gamePlayers = zipWith mkPlayer (map PlayerHandle [0..]) ps }


mkPlayer :: PlayerHandle -> PlayerData -> Player
mkPlayer handle (PlayerData hero deck) = Player {
    _playerHandle = handle,
    _playerDeck = deck,
    _playerExcessDrawCount = 0,
    _playerHand = Hand [],
    _playerMinions = [],
    _playerTotalManaCrystals = 0,
    _playerEmptyManaCrystals = 0,
    _playerHero = mkBoardHero hero }


mkBoardHero :: Hero -> BoardHero
mkBoardHero hero = BoardHero {
    _boardHeroCurrHealth = _heroHealth hero,
    _boardHeroArmor = 0,
    _boardHero = hero }


getPlayer :: PlayerHandle -> Lens' GameState Player
getPlayer handle f st = fmap put' get'
    where
        players = st^.gamePlayers
        put' player = let
            g p = case p^.playerHandle == handle of
                True -> player
                False -> p
            in set gamePlayers (map g players) st
        get' = f $ fromJust $ find (\p -> p^.playerHandle == handle) players


getActivePlayerHandle :: (HearthMonad m) => Hearth m PlayerHandle
getActivePlayerHandle = do
    (h : _) <- view gamePlayerTurnOrder
    return h


isActivePlayer :: (HearthMonad m) => PlayerHandle -> Hearth m Bool
isActivePlayer h = liftM (h ==) getActivePlayerHandle


zoomPlayer :: (Zoom m n Player GameState, Functor (Zoomed m c), Zoomed n ~ Zoomed m) => PlayerHandle -> m c -> n c
zoomPlayer = zoom . getPlayer


zoomHero :: (Zoom m n BoardHero GameState, Functor (Zoomed m c), Zoomed n ~ Zoomed m) => PlayerHandle -> m c -> n c
zoomHero handle = zoom (getPlayer handle.playerHero)


getPlayerHandles :: (HearthMonad m) => Hearth m [PlayerHandle]
getPlayerHandles = viewListOf $ gamePlayers.traversed.playerHandle


genRawHandle :: (HearthMonad m) => Hearth m RawHandle
genRawHandle = do
    handle <- view $ gameHandleSeed
    gameHandleSeed += 1
    return handle


class GenHandle handle where
    genHandle :: (HearthMonad m) => Hearth m handle

instance GenHandle MinionHandle where
    genHandle = liftM MinionHandle genRawHandle


runGame :: (HearthMonad m) => Hearth m GameResult
runGame = logCall 'runGame $ do
    prompt $ PromptGameEvent GameBegins
    initGame
    tickTurn
    let gameResult = GameResult
    prompt $ PromptGameEvent $ GameEnds gameResult
    return gameResult


initGame :: (HearthMonad m) => Hearth m ()
initGame = logCall 'initGame $ do
    flipCoin
    handles <- getPlayerHandles
    mapM_ initPlayer handles


flipCoin :: (HearthMonad m) => Hearth m ()
flipCoin = logCall 'flipCoin $ getPlayerHandles >>= \handles -> do
    handle <- prompt $ PromptPickRandom $ NonEmpty.fromList handles
    let handles' = dropWhile (/= handle) $ cycle handles
    gamePlayerTurnOrder .= handles'


initPlayer :: (HearthMonad m) => PlayerHandle -> Hearth m ()
initPlayer = initHand


initHand :: (HearthMonad m) => PlayerHandle -> Hearth m ()
initHand handle = logCall 'initHand $ do
    shuffleDeck handle
    numCards <- isActivePlayer handle >>= return . \case
        True -> 3
        False -> 4
    drawnCards <- drawCards handle numCards
    keptCards <- guardedPrompt (PromptMulligan handle drawnCards) $ let
        in flip (on isSubsetOf $ map handCardName) drawnCards
    let tossedCards = foldr (deleteBy $ on (==) handCardName) keptCards drawnCards
        tossedCards' = map handToDeck tossedCards
    drawCards handle (length tossedCards) >>= \case
        [] -> return ()
        _ -> do
            getPlayer handle.playerDeck.deckCards %= (tossedCards' ++)
            shuffleDeck handle


drawCards :: (HearthMonad m) => PlayerHandle -> Int -> Hearth m [HandCard]
drawCards handle = logCall 'drawCards $ liftM catMaybes . flip replicateM (drawCard handle)


putInHand :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Bool
putInHand handle card = logCall 'putInHand $ zoom (getPlayer handle.playerHand.handCards) $ do
    to length >>=. \case
        10 -> return False
        _ -> do
            id %= (card :)
            return True


removeFromHand :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Bool
removeFromHand handle card = logCall 'removeFromHand $ zoom (getPlayer handle.playerHand.handCards) $ do
    hand <- view id
    id %= deleteBy (on (==) handCardName) card
    hand' <- view id
    return $ length hand /= length hand'


drawCard :: (HearthMonad m) => PlayerHandle -> Hearth m (Maybe HandCard)
drawCard handle = logCall 'drawCard $ getPlayer handle.playerDeck >>=. \case
    Deck [] -> do
        getPlayer handle.playerExcessDrawCount += 1
        excess <- view $ getPlayer handle.playerExcessDrawCount
        damagePlayerHero handle $ Damage excess
        return Nothing
    Deck (c:cs) -> do
        let c' = deckToHand c
            deck = Deck cs
            promptDraw eCard = do
                prompt $ PromptGameEvent $ CardDrawn handle eCard deck
                return $ either (const Nothing) Just eCard
        getPlayer handle.playerDeck .= deck
        putInHand handle c' >>= \case
            False -> promptDraw $ Left c
            True -> promptDraw $ Right c'


damagePlayerHero :: (HearthMonad m) => PlayerHandle -> Damage -> Hearth m ()
damagePlayerHero handle damage = logCall 'damagePlayerHero $ zoomHero handle $ do
    let Damage amount = damage
        delta = Health amount
    oldHealth <- view boardHeroCurrHealth
    boardHeroCurrHealth -= delta
    prompt $ PromptGameEvent $ HeroTakesDamage handle oldHealth damage


isPlayerHeroDead :: (HearthMonad m) => PlayerHandle -> Hearth m Bool
isPlayerHeroDead handle = logCall 'isPlayerHeroDead $ do
    health <- view $ getPlayer handle.playerHero.boardHeroCurrHealth
    return $ health <= 0


shuffleDeck :: (HearthMonad m) => PlayerHandle -> Hearth m ()
shuffleDeck handle = logCall 'shuffleDeck $ zoomPlayer handle $ do
    Deck deck <- view playerDeck
    deck' <- let
        f = sort . map deckCardName
        in liftM Deck $ guardedPrompt (PromptShuffle deck) $ on (==) f deck
    prompt $ PromptGameEvent $ DeckShuffled handle deck'
    playerDeck .= deck'


isGameOver :: (HearthMonad m) => Hearth m Bool
isGameOver = logCall 'isGameOver $ do
    handles <- getPlayerHandles
    anyM isPlayerHeroDead handles


tickTurn :: (HearthMonad m) => Hearth m ()
tickTurn = do
    runTurn
    isGameOver >>= \case
        False -> tickTurn
        True -> return ()


runTurn :: (HearthMonad m) => Hearth m ()
runTurn = logCall 'runTurn $ do
    beginTurn
    pumpTurn
    endTurn


gainManaCrystal :: (HearthMonad m) => CrystalState -> PlayerHandle -> Hearth m ()
gainManaCrystal crystalState handle = logCall 'gainManaCrystal $ zoomPlayer handle $ do
    emptyCount <- view playerEmptyManaCrystals
    totalCount <- view playerTotalManaCrystals
    case totalCount of
        10 -> do
            prompt $ PromptGameEvent $ GainsManaCrystal handle Nothing
            case emptyCount of
                0 -> return ()
                _ -> do
                    playerEmptyManaCrystals -= 1
                    prompt $ PromptGameEvent $ ManaCrystalsRefill handle 1
        _ -> do
            playerTotalManaCrystals += 1
            case crystalState of
                CrystalFull -> return ()
                CrystalEmpty -> playerEmptyManaCrystals += 1
            prompt $ PromptGameEvent $ GainsManaCrystal handle $ Just crystalState


beginTurn :: (HearthMonad m) => Hearth m ()
beginTurn = logCall 'beginTurn $ do
    handle <- getActivePlayerHandle
    gainManaCrystal CrystalFull handle
    getPlayer handle.playerEmptyManaCrystals .= 0
    _ <- drawCard handle
    return ()


endTurn :: (HearthMonad m) => Hearth m ()
endTurn = logCall 'endTurn $ do
    gamePlayerTurnOrder %= tail


data TurnEvolution = ContinueTurn | EndTurn
    deriving (Eq)


pumpTurn :: (HearthMonad m) => Hearth m ()
pumpTurn = logCall 'pumpTurn $ do
    let cond = \case
            Nothing -> True
            Just EndTurn -> True
            Just ContinueTurn -> False
    _ <- iterateUntil cond pumpTurn'
    return ()


pumpTurn' :: (HearthMonad m) => Hearth m (Maybe TurnEvolution)
pumpTurn' = logCall 'pumpTurn' $ isGameOver >>= \case
    True -> return Nothing
    False -> performAction


performAction :: (HearthMonad m) => Hearth m (Maybe TurnEvolution)
performAction = logCall 'performAction $ do
    snapshot <- gets GameSnapshot
    prompt (PromptAction snapshot) >>= liftM Just . \case
        ActionPlayerConceded _ -> $todo 'pumpTurn' "concede"
        ActionPlayCard card pos -> actionPlayCard card pos
        ActionEndTurn -> return EndTurn


isCardInHand :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Bool
isCardInHand handle card = logCall 'isCardInHand $ local id $ removeFromHand handle card


insertAt :: Int -> a -> [a] -> [a]
insertAt n x xs = let
    (left, right) = splitAt n xs
    in left ++ [x] ++ right


placeOnBoard :: (HearthMonad m) => PlayerHandle -> BoardPos -> Minion -> Hearth m (Maybe BoardMinion)
placeOnBoard handle (BoardPos pos) minion = logCall 'placeOnBoard $ do
    minionHandle <- genHandle
    let minion' = BoardMinion {
            _boardMinionCurrAttack = minion^.minionAttack,
            _boardMinionCurrHealth = minion^.minionHealth,
            _boardMinionEnchantments = [],
            _boardMinionAbilities = minion^.minionAbilities,
            _boardMinionHandle = minionHandle,
            _boardMinion = minion }
    zoom (getPlayer handle.playerMinions) $ do
        to length >>=. \case
            7 -> return Nothing
            len -> case 0 <= pos && pos <= len of
                False -> return Nothing
                True -> do
                    id %= insertAt pos minion'
                    return $ Just minion'


actionPlayCard :: (HearthMonad m) => HandCard -> BoardPos -> Hearth m TurnEvolution
actionPlayCard card pos = logCall 'actionPlayCard $ do
    handle <- getActivePlayerHandle
    _ <- playCard handle card pos
    return ContinueTurn


playCard :: (HearthMonad m) => PlayerHandle -> HandCard -> BoardPos -> Hearth m Result
playCard handle card pos = logCall 'playCard $ do
    st <- get
    mBoardMinion <- playCard' handle card pos >>= \case
        Just bm -> return $ Just bm
        Nothing -> do
            put st
            return Nothing;
    let result = maybe Failure (const Success) mBoardMinion
    prompt $ PromptGameEvent $ PlayedCard handle card result
    case mBoardMinion of
        Nothing -> return ()
        Just bm -> enactAnyBattleCries bm
    return result


enactAnyBattleCries :: (HearthMonad m) => BoardMinion -> Hearth m ()
enactAnyBattleCries minion = logCall 'enactAnyBattleCries $ do
    forM_ (minion^.boardMinionAbilities) $ \case
        KeywordAbility (BattleCry effect) -> enactBattleCry effect
        _ -> return ()


enactBattleCry :: (HearthMonad m) => Effect -> Hearth m ()
enactBattleCry = logCall 'enactBattleCry . enactEffect


enactEffect :: (HearthMonad m) => Effect -> Hearth m ()
enactEffect = logCall 'enactEffect . \case
    With elect -> enactEffect =<< reifyElect elect
    DrawCards n handle -> drawCards handle n >> return ()


reifyElect :: (HearthMonad m) => Elect -> Hearth m Effect
reifyElect = logCall 'reifyElect . \case
    Owner f -> do
        handle <- getActivePlayerHandle
        return $ f handle


playCard' :: (HearthMonad m) => PlayerHandle -> HandCard -> BoardPos -> Hearth m (Maybe BoardMinion)
playCard' handle card pos = logCall 'playCard' $ removeFromHand handle card >>= \case
    False -> return Nothing
    True -> do
        payCost handle (costOf card) >>= \case
            Failure -> return Nothing
            Success -> case card of
                HandCardMinion hm -> do
                    placeOnBoard handle pos $ case hm of
                        HandMinion minion' -> minion'


costOf :: HandCard -> Cost
costOf = \case
    HandCardMinion minion -> minion^.handMinion.minionCost


payCost :: (HearthMonad m) => PlayerHandle -> Cost -> Hearth m Result
payCost who = logCall 'payCost $  \case
    ManaCost mana -> payManaCost who mana


payManaCost :: (HearthMonad m) => PlayerHandle -> Mana -> Hearth m Result
payManaCost who (Mana cost) = logCall 'payManaCost $ zoomPlayer who $ do
    totalMana <- view playerTotalManaCrystals
    emptyMana <- view playerEmptyManaCrystals
    let availableMana = totalMana - emptyMana
    case cost <= availableMana of
        False -> return Failure
        True -> do
            playerEmptyManaCrystals += cost
            return Success
































































