{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeSynonymInstances #-}


module Hearth.Engine (
    module Hearth.Engine,
    module Hearth.Engine.Data,
) where


--------------------------------------------------------------------------------


import Control.Error.TH
import Control.Lens hiding (Each)
import Control.Lens.Helper
import Control.Monad.Loops
import Control.Monad.Prompt hiding (Effect)
import Control.Monad.Reader
import Control.Monad.State
import Data.Function
import Data.List
import Data.List.Ordered
import Data.Maybe
import Data.NonEmpty (NonEmpty)
import qualified Data.NonEmpty as NonEmpty
import Data.Proxy
import Hearth.Action
import Hearth.Cards (cardByName)
import Hearth.DeckToHand
import Hearth.Engine.Data
import Hearth.GameEvent
import Hearth.HandToDeck
import Hearth.Model
import Hearth.Names (CardName(BasicCardName))
import Hearth.Names.Basic (BasicCardName(TheCoin))
import Hearth.Prompt


--------------------------------------------------------------------------------


guardedPrompt :: (MonadPrompt p m) => p a -> (a -> m Bool) -> m a
guardedPrompt p predicate = prompt p >>= \x -> predicate x >>= \case
    True -> return x
    False -> guardedPrompt p predicate


isSubsetOf :: (Ord a) => [a] -> [a] -> Bool
isSubsetOf = subset `on` sort


runQuery :: (HearthMonad m) => GameSnapshot -> Hearth m a -> m a
runQuery snapshot query = evalStateT (unHearth query') $ snapshot^.snapshotGameState
    where
        query' = logCall 'runQuery query


runHearth :: (HearthMonad m) => Pair PlayerData -> m GameResult
runHearth = evalStateT (unHearth runHearth') . mkGameState


newHandle :: (HearthMonad m) => Hearth m RawHandle
newHandle = do
    gameHandleSeed += 1
    view gameHandleSeed


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
    _playerTemporaryManaCrystals = 0,
    _playerHero = mkBoardHero hero }


mkBoardHero :: Hero -> BoardHero
mkBoardHero hero = BoardHero {
    _boardHeroDamage = 0,
    _boardHeroArmor = 0,
    _boardHeroAttackCount = 0,
    _boardHero = hero }


getPlayer :: PlayerHandle -> Lens' GameState Player
getPlayer pHandle = lens getter setter
    where
        getter st = case find (\p -> p^.playerHandle == pHandle) $ st^.gamePlayers of
            Just p -> p
            Nothing -> $logicError 'getPlayer "Non-existent handle."
        setter st p' = st & gamePlayers.traversed %~ \p ->
            case p^.playerHandle == pHandle of
                True -> p'
                False -> p


getMinion :: MinionHandle -> Lens' GameState BoardMinion
getMinion bmHandle = lens getter setter
    where
        getter st = let
            players = st^.gamePlayers
            minions = players >>= \p -> p^.playerMinions
            in case find (\bm -> bm^.boardMinionHandle == bmHandle) minions of
                Just bm -> bm
                Nothing -> $logicError 'getMinion "Non-existent handle."
        setter st bm' = st & gamePlayers.traversed.playerMinions.traversed %~ \bm ->
            case bm^.boardMinionHandle == bmHandle of
                True -> bm'
                False -> bm


getActivePlayerHandle :: (HearthMonad m) => Hearth m PlayerHandle
getActivePlayerHandle = logCall 'getActivePlayerHandle $ do
    (h : _) <- view gamePlayerTurnOrder
    return h


getNonActivePlayerHandle :: (HearthMonad m) => Hearth m PlayerHandle
getNonActivePlayerHandle = logCall 'getNonActivePlayerHandle $ do
    (_ : h : _) <- view gamePlayerTurnOrder
    return h


isActivePlayer :: (HearthMonad m) => PlayerHandle -> Hearth m Bool
isActivePlayer h = liftM (h ==) getActivePlayerHandle


class Controllable a where
    controllerOf :: (HearthMonad m) => a -> Hearth m PlayerHandle


instance Controllable (Handle a) where
    controllerOf = logCall 'controllerOf $ \case
        SpellHandle {} -> $todo 'controllerOf "xxx"
        h @ MinionHandle {} -> do
            players <- view gamePlayers
            let isEq minion = minion^.boardMinionHandle == h
                players' = flip filter players $ \player -> any isEq $ player^.playerMinions
            case players' of
                [player] -> return $ player^.playerHandle
                _ -> $logicError 'controllerOf "Invalid handle."
        h @ PlayerHandle {} -> return h
        MinionCharacter h -> controllerOf h
        PlayerCharacter h -> controllerOf h


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


instance GenHandle SpellHandle where
    genHandle = liftM SpellHandle genRawHandle


runHearth' :: (HearthMonad m) => Hearth m GameResult
runHearth' = logCall 'runHearth' $ do
    do
        snap <- gets GameSnapshot
        prompt $ PromptGameEvent snap GameBegins
    initGame
    tickTurn
    let gameResult = GameResult
    do
        snap <- gets GameSnapshot
        prompt $ PromptGameEvent snap $ GameEnds gameResult
    return gameResult


initGame :: (HearthMonad m) => Hearth m ()
initGame = logCall 'initGame $ do
    flipCoin
    handles <- getPlayerHandles
    mapM_ initPlayer handles


flipCoin :: (HearthMonad m) => Hearth m ()
flipCoin = logCall 'flipCoin $ getPlayerHandles >>= \handles -> do
    snap <- gets GameSnapshot
    AtRandomPick handle <- prompt $ PromptPickAtRandom $ PickPlayer snap $ NonEmpty.fromList handles
    let handles' = dropWhile (/= handle) $ cycle handles
    gamePlayerTurnOrder .= handles'


initPlayer :: (HearthMonad m) => PlayerHandle -> Hearth m ()
initPlayer = initHand


initHand :: (HearthMonad m) => PlayerHandle -> Hearth m ()
initHand handle = logCall 'initHand $ do
    shuffleDeck handle
    isFirst <- isActivePlayer handle
    let numCards = case isFirst of
            True -> 3
            False -> 4
    drawnCards <- drawCards handle numCards
    keptCards <- guardedPrompt (PromptMulligan handle drawnCards) $ \keptCards -> let
        in case on isSubsetOf (map handCardName) keptCards drawnCards of
            True -> return True
            False -> do
                prompt $ PromptError InvalidMulligan
                return False
    let tossedCards = foldr (deleteBy $ on (==) handCardName) keptCards drawnCards
        tossedCards' = map handToDeck tossedCards
    drawCards handle (length tossedCards) >>= \case
        [] -> return ()
        _ -> do
            getPlayer handle.playerDeck.deckCards %= (tossedCards' ++)
            shuffleDeck handle
    case isFirst of
        True -> return ()
        False -> let
            theCoin = deckToHand $ cardByName $ BasicCardName TheCoin
            in getPlayer handle.playerHand.handCards %= (theCoin :)


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
        receiveDamage (PlayerCharacter handle) $ Damage excess
        return Nothing
    Deck (c:cs) -> do
        let c' = deckToHand c
            deck = Deck cs
            promptDraw eCard = do
                snap <- gets GameSnapshot
                prompt $ PromptGameEvent snap $ CardDrawn handle eCard deck
                return $ either (const Nothing) Just eCard
        getPlayer handle.playerDeck .= deck
        putInHand handle c' >>= \case
            False -> promptDraw $ Left c
            True -> promptDraw $ Right c'


isDead :: (HearthMonad m) => CharacterHandle -> Hearth m Bool
isDead character = logCall 'isDead $ isMortallyWounded character >>= \case
    True -> return True
    False -> case character of
        PlayerCharacter {} -> return False
        MinionCharacter minion -> view $ getMinion minion.boardMinionPendingDestroy


isMortallyWounded :: (HearthMonad m) => CharacterHandle -> Hearth m Bool
isMortallyWounded = logCall 'isMortallyWounded $ liftM (<= 0) . dynamicRemainingHealth


shuffleDeck :: (HearthMonad m) => PlayerHandle -> Hearth m ()
shuffleDeck handle = logCall 'shuffleDeck $ do
    deck' <- zoom (getPlayer handle) $ do
        Deck deck <- view playerDeck
        deck' <- liftM Deck $ guardedPrompt (PromptShuffle deck) $ \deck' -> let
            f = sort . map deckCardName
            in case on (==) f deck deck' of
                True -> return True
                False -> do
                    prompt $ PromptError InvalidShuffle
                    return False
        playerDeck .= deck'
        return deck'
    snap <- gets GameSnapshot
    prompt $ PromptGameEvent snap $ DeckShuffled handle deck'


isGameOver :: (HearthMonad m) => Hearth m Bool
isGameOver = logCall 'isGameOver $ do
    handles <- getPlayerHandles
    anyM (isDead . PlayerCharacter) handles


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
gainManaCrystal crystalState handle = logCall 'gainManaCrystal $ do
    totalCount <- view $ getPlayer handle.playerTotalManaCrystals
    let promptGameEvent e = do
            snap <- gets GameSnapshot
            prompt $ PromptGameEvent snap e
    case totalCount of
        10 -> do
            let refillCount = case crystalState of
                    CrystalFull -> 1
                    CrystalEmpty -> 0
                    CrystalTemporary -> 1
            let realCount = case crystalState of
                    CrystalFull -> 1
                    CrystalEmpty -> 1
                    CrystalTemporary -> 0
            getPlayer handle.playerTemporaryManaCrystals %= max 0 . subtract realCount
            promptGameEvent $ GainsManaCrystal handle Nothing
            getPlayer handle.playerEmptyManaCrystals %= max 0 . subtract refillCount
            promptGameEvent $ ManaCrystalsRefill handle refillCount
        _ -> do
            getPlayer handle.playerTotalManaCrystals += 1
            zoom (getPlayer handle) $ case crystalState of
                CrystalFull -> return ()
                CrystalEmpty -> playerEmptyManaCrystals += 1
                CrystalTemporary -> playerTemporaryManaCrystals += 1
            promptGameEvent $ GainsManaCrystal handle $ Just crystalState


beginTurn :: (HearthMonad m) => Hearth m ()
beginTurn = logCall 'beginTurn $ do
    handle <- getActivePlayerHandle
    gainManaCrystal CrystalFull handle
    zoom (getPlayer handle) $ do
        playerEmptyManaCrystals .= 0
        playerHero.boardHeroAttackCount .= 0
        playerMinions.traversed.boardMinionAttackCount .= 0
        playerMinions.traversed.boardMinionNewlySummoned .= False
    _ <- drawCard handle
    return ()


endTurn :: (HearthMonad m) => Hearth m ()
endTurn = logCall 'endTurn $ do
    handle <- getActivePlayerHandle
    zoom (getPlayer handle) $ do
        tempCount <- view playerTemporaryManaCrystals
        playerTotalManaCrystals %= max 0 . subtract tempCount
        playerEmptyManaCrystals %= max 0 . subtract tempCount
        playerTemporaryManaCrystals .= 0
    gamePlayerTurnOrder %= tail


data EndTurn = EndTurn
    deriving (Eq)


pumpTurn :: (HearthMonad m) => Hearth m ()
pumpTurn = logCall 'pumpTurn $ do
    let cond = \case
            Nothing -> True
            Just evo -> case evo of
                Right EndTurn -> True
                Left () -> False
    _ <- iterateUntil cond pumpTurn'
    return ()


pumpTurn' :: (HearthMonad m) => Hearth m (Maybe (Either () EndTurn))
pumpTurn' = logCall 'pumpTurn' $ isGameOver >>= \case
    True -> return Nothing
    False -> liftM Just performAction


performAction :: (HearthMonad m) => Hearth m (Either () EndTurn)
performAction = logCall 'performAction $ do
    snapshot <- gets GameSnapshot
    evolution <- prompt (PromptAction snapshot) >>= enactAction
    clearDeadMinions
    return $ case evolution of
        Left _ -> Left ()
        Right EndTurn -> Right EndTurn
    
    
enactAction :: (HearthMonad m) => Action -> Hearth m (Either Result EndTurn)
enactAction = logCall 'enactAction . \case
    ActionPlayerConceded p -> concede p >> return (Left Success)
    ActionPlayMinion card pos -> liftM Left $ actionPlayMinion card pos
    ActionPlaySpell card -> liftM Left $ actionPlaySpell card
    ActionAttack attacker defender -> liftM Left $ actionAttack attacker defender
    ActionEndTurn -> return $ Right EndTurn


concede :: (HearthMonad m) => PlayerHandle -> Hearth m ()
concede p = do
    health <- dynamicMaxHealth p
    getPlayer p.playerHero.boardHeroDamage .= Damage (unHealth health)


isCardInHand :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Bool
isCardInHand handle card = logCall 'isCardInHand $ local id $ removeFromHand handle card


insertAt :: Int -> a -> [a] -> [a]
insertAt n x xs = let
    (left, right) = splitAt n xs
    in left ++ [x] ++ right


placeOnBoard :: (HearthMonad m) => PlayerHandle -> BoardPos -> Minion -> Hearth m (Maybe MinionHandle)
placeOnBoard handle (BoardPos pos) minion = logCall 'placeOnBoard $ do
    minionHandle <- genHandle
    let minion' = BoardMinion {
            _boardMinionDamage = 0,
            _boardMinionEnchantments = [],
            _boardMinionAbilities = minion^.minionAbilities,
            _boardMinionAttackCount = 0,
            _boardMinionNewlySummoned = True,
            _boardMinionPendingDestroy = False,
            _boardMinionHandle = minionHandle,
            _boardMinion = minion }
    zoom (getPlayer handle.playerMinions) $ do
        to length >>=. \case
            7 -> return Nothing
            len -> case 0 <= pos && pos <= len of
                False -> return Nothing
                True -> do
                    id %= insertAt pos minion'
                    return $ Just minionHandle


actionAttack :: (HearthMonad m) => CharacterHandle -> CharacterHandle -> Hearth m Result
actionAttack attacker defender = logCall 'actionAttack $ do
    enactAttack attacker defender


actionPlayMinion :: (HearthMonad m) => HandCard -> BoardPos -> Hearth m Result
actionPlayMinion card pos = logCall 'actionPlayMinion $ do
    pHandle <- getActivePlayerHandle
    playMinion pHandle card pos


actionPlaySpell :: (HearthMonad m) => HandCard -> Hearth m Result
actionPlaySpell card = logCall 'actionPlaySpell $ do
    handle <- getActivePlayerHandle
    playSpell handle card


playMinion :: (HearthMonad m) => PlayerHandle -> HandCard -> BoardPos -> Hearth m Result
playMinion pHandle card pos = logCall 'playMinion $ do
    st <- get
    playMinion' pHandle card pos >>= \case
        Nothing -> do
            put st
            return Failure
        Just bmHandle -> do
            snap <- gets GameSnapshot
            prompt $ PromptGameEvent snap $ PlayedMinion pHandle bmHandle
            result <- enactAnyBattleCries bmHandle
            when (result == Failure) $ put st
            return result


playMinion' :: (HearthMonad m) => PlayerHandle -> HandCard -> BoardPos -> Hearth m (Maybe MinionHandle)
playMinion' handle card pos = logCall 'playMinion' $ playCommon handle card >>= \case
    Failure -> return Nothing
    Success -> case card of
        HandCardMinion minion -> placeOnBoard handle pos minion
        _ -> return Nothing


playSpell :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Result
playSpell pHandle card = logCall 'playSpell $ do
    st <- get
    result <- playSpell' pHandle card >>= \case
        Nothing -> return Failure
        Just sHandle -> do
            snap <- gets GameSnapshot
            prompt $ PromptGameEvent snap $ PlayedSpell pHandle sHandle
            enactSpell sHandle
    when (result == Failure) $ put st
    return result


-- TODO: This should return a SpellHandle instead of a Spell
playSpell' :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m (Maybe Spell)
playSpell' handle card = logCall 'playSpell' $ playCommon handle card >>= \case
    Failure -> return Nothing
    Success -> case card of
        HandCardSpell spell -> return $ Just spell
        _ -> return Nothing


-- TODO: This should accept a SpellHandle instead of a Spell
enactSpell :: (HearthMonad m) => Spell -> Hearth m Result
enactSpell spell = do
    st <- get
    let f = spell^.spellEffect
    genHandle >>= enactElectionEffect f . purePick >>= \case
        Available (TargetedPick _) -> return Success
        _ -> put st >> return Failure


enactAnyDeathrattles :: (HearthMonad m) => MinionHandle -> Hearth m ()
enactAnyDeathrattles bmHandle = logCall 'enactAnyDeathrattles $ do
    abilities <- dynamicAbilities bmHandle
    forM_ abilities $ \case
        KeywordAbility (Deathrattle effect) -> enactDeathrattle bmHandle effect
        _ -> return ()


enactAnyBattleCries :: (HearthMonad m) => MinionHandle -> Hearth m Result
enactAnyBattleCries bmHandle = logCall 'enactAnyBattleCries $ do
    st <- get
    abilities <- dynamicAbilities bmHandle
    result <- liftM condensePickResults $ forM abilities $ \case
        KeywordAbility (Battlecry effect) -> enactBattlecry bmHandle effect
        _ -> return $ purePick ()
    case result of
        NotAvailable -> do
            put st
            return Success
        Available result' -> case result' of
            TargetedPick _ -> return Success
            AbortTargetedPick -> do
                put st
                return Failure


enactDeathrattle :: (HearthMonad m) => MinionHandle -> (MinionHandle -> Effect) -> Hearth m ()
enactDeathrattle handle f = logCall 'enactDeathrattle $ do
    (_ :: SimplePickResult AtRandom) <- enactEffect $ f handle
    return ()


enactBattlecry :: (HearthMonad m) => MinionHandle -> (MinionHandle -> ElectionEffect Targeted) -> Hearth m (SimplePickResult Targeted)
enactBattlecry handle f = logCall 'enactBattlecry $ do
    enactElectionEffect f $ purePick handle


enactEffect :: (HearthMonad m, EnactElectionEffect s) => Effect -> Hearth m (SimplePickResult s)
enactEffect = logCall 'enactEffect . \case
    Elect elect -> enactElect elect >>= return . \case
        NotAvailable -> NotAvailable
        Available (AtRandomPick _) -> purePick ()
    With with -> enactWith with
    ForEach handles cont -> enactForEach handles cont
    Sequence effects -> sequenceEffects effects
    DrawCards handle n -> drawCards handle n >> return success
    KeywordEffect effect -> enactKeywordEffect effect >> return success
    DealDamage handle damage -> receiveDamage handle damage >> return success
    Enchant handle enchantments -> enchant handle enchantments >> return success
    GiveAbility handle abilities -> giveAbilities handle abilities >> return success
    GainManaCrystal crystalState handle -> gainManaCrystal crystalState handle >> return success
    DestroyMinion handle -> destroyMinion handle >> return success
    RestoreHealth handle amount -> restoreHealth handle amount >> return success
    where
        success = purePick ()


restoreHealth :: (HearthMonad m) => CharacterHandle -> Int -> Hearth m ()
restoreHealth charHandle amount = logCall 'restoreHealth $ case charHandle of
    MinionCharacter handle -> getMinion handle.boardMinionDamage %= restore
    PlayerCharacter handle -> getPlayer handle.playerHero.boardHeroDamage %= restore
    where
        restore = min 0 . (subtract $ Damage amount)


destroyMinion :: (HearthMonad m) => MinionHandle -> Hearth m ()
destroyMinion handle = logCall 'destroyMinion $ do
    getMinion handle.boardMinionPendingDestroy .= True


enactWith :: (HearthMonad m, EnactElectionEffect s) => With -> Hearth m (SimplePickResult s)
enactWith = logCall 'enactWith $ \case
    All x -> enactAll x
    Unique x -> enactUnique x


enactForEach :: (HearthMonad m, EnactElectionEffect s) => [a] -> (a -> Effect) -> Hearth m (SimplePickResult s)
enactForEach handles cont = logCall 'enactForEach $ do
    liftM condensePickResults $ forM handles (enactEffect . cont)


sequenceEffects :: (HearthMonad m, EnactElectionEffect s, Eq (PickResult s ())) => [Effect] -> Hearth m (SimplePickResult s)
sequenceEffects effects = liftM condensePickResults $ mapM enactEffect effects


condensePickResults :: (EnactElectionEffect s) => [SimplePickResult s] -> SimplePickResult s
condensePickResults results = case dropWhile (== purePick ()) results of
    [] -> purePick ()
    r : _ -> r


giveAbilities :: (HearthMonad m) => MinionHandle -> [Ability] -> Hearth m ()
giveAbilities handle abilities = logCall 'giveAbilities $ do
    getMinion handle.boardMinionAbilities %= (abilities ++)


enchant :: (HearthMonad m) => MinionHandle -> [Enchantment] -> Hearth m ()
enchant handle enchantments = logCall 'enchant $ do
    getMinion handle.boardMinionEnchantments %= (enchantments ++)


isDamaged :: BoardMinion -> Bool
isDamaged bm = bm^.boardMinionDamage > 0


isEnraged :: (HearthMonad m) => MinionHandle -> Hearth m Bool
isEnraged bmHandle = do
    bm <- view $ getMinion bmHandle
    abilities <- dynamicAbilities bmHandle
    return $ isDamaged bm && any isEnrage abilities
    where
        isEnrage = \case
            KeywordAbility (Enrage {}) -> True
            _ -> False


dynamicAbilities :: (HearthMonad m) => MinionHandle -> Hearth m [Ability]
dynamicAbilities bmHandle = do
    bm <- view $ getMinion bmHandle
    return $ bm^.boardMinionAbilities >>= \ability -> case ability of
        KeywordAbility (Enrage abilities _) -> case isDamaged bm of
            True -> ability : abilities  -- TODO: Need to check correct interleaving.
            False -> [ability]
        _ -> [ability]


dynamicEnchantments :: (HearthMonad m) => MinionHandle -> Hearth m [Enchantment]
dynamicEnchantments bmHandle = logCall 'dynamicEnchantments $ do
    bm <- view $ getMinion bmHandle
    let baseEnchantments = bm^.boardMinionEnchantments
        enrageEnchantments = case isDamaged bm of
            False -> []
            True -> bm^.boardMinionAbilities >>= \case
                KeywordAbility (Enrage _ es) -> es
                _ -> []
    return $ baseEnchantments ++ enrageEnchantments -- TODO: Need to check correct interleaving.


class GetCharacterHandle a where
    characterHandle :: a -> CharacterHandle


instance GetCharacterHandle PlayerHandle where
    characterHandle = PlayerCharacter


instance GetCharacterHandle MinionHandle where
    characterHandle = MinionCharacter


instance GetCharacterHandle CharacterHandle where
    characterHandle = id


instance GetCharacterHandle BoardMinion where
    characterHandle = characterHandle . _boardMinionHandle


class (Controllable a, GetCharacterHandle a) => CharacterTraits a where
    getDamage :: (HearthMonad m) => a -> Hearth m Damage
    dynamicAttack :: (HearthMonad m) => a -> Hearth m Attack
    dynamicMaxHealth :: (HearthMonad m) => a -> Hearth m Health
    dynamicMaxAttackCount :: (HearthMonad m) => a -> Hearth m Int
    getAttackCount :: (HearthMonad m) => a -> Hearth m Int
    bumpAttackCount :: (HearthMonad m) => a -> Hearth m ()
    hasSummoningSickness :: (HearthMonad m) => a -> Hearth m Bool


instance CharacterTraits PlayerHandle where
    getDamage pHandle = logCall 'getDamage $ do
        view $ getPlayer pHandle.playerHero.boardHeroDamage
    dynamicAttack pHandle = logCall 'dynamicAttack $ do
        view $ getPlayer pHandle.playerHero.boardHero.heroAttack
    dynamicMaxHealth pHandle = logCall 'dynamicMaxHealth $ do
        view $ getPlayer pHandle.playerHero.boardHero.heroHealth
    dynamicMaxAttackCount _ = logCall 'dynamicMaxAttackCount $ do
        return 1
    getAttackCount pHandle = logCall 'getAttackCount $ do
        view $ getPlayer pHandle.playerHero.boardHeroAttackCount
    bumpAttackCount pHandle = logCall 'bumpAttackCount $ do
        getPlayer pHandle.playerHero.boardHeroAttackCount += 1
    hasSummoningSickness _ = return False


instance CharacterTraits MinionHandle where
    getDamage bmHandle = logCall 'getDamage $ do
        view $ getMinion bmHandle.boardMinionDamage
    dynamicAttack bmHandle = logCall 'dynamicAttack $ do
        bm <- view $ getMinion bmHandle
        enchantments <- dynamicEnchantments bmHandle
        let delta = sum $ flip mapMaybe enchantments $ \case
                StatsDelta a _ -> Just a
        return $ bm^.boardMinion.minionAttack + delta
    dynamicMaxHealth bmHandle = logCall 'dynamicMaxHealth $ do
        bm <- view $ getMinion bmHandle
        enchantments <- dynamicEnchantments bmHandle
        let delta = sum $ flip mapMaybe enchantments $ \case
                StatsDelta _ h -> Just h
        return $ bm^.boardMinion.minionHealth + delta
    dynamicMaxAttackCount _ = logCall 'dynamicMaxAttackCount $ do
        return 1
    getAttackCount bmHandle = logCall 'getAttackCount $ do
        view $ getMinion bmHandle.boardMinionAttackCount
    bumpAttackCount bmHandle = logCall 'bumpAttackCount $ do
        getMinion bmHandle.boardMinionAttackCount += 1
    hasSummoningSickness bmHandle = logCall 'hasSummoningSickness $ do
        bm <- view $ getMinion bmHandle
        case bm^.boardMinionNewlySummoned of
            False -> return False
            True -> liftM not $ dynamicHasCharge bmHandle


instance CharacterTraits CharacterHandle where
    getDamage = logCall 'getDamage $ \case
        PlayerCharacter h -> getDamage h
        MinionCharacter h -> getDamage h
    dynamicAttack = logCall 'dynamicAttack $ \case
        PlayerCharacter h -> dynamicAttack h
        MinionCharacter h -> dynamicAttack h
    dynamicMaxHealth = logCall 'dynamicMaxHealth $ \case
        PlayerCharacter h -> dynamicMaxHealth h
        MinionCharacter h -> dynamicMaxHealth h
    dynamicMaxAttackCount = logCall 'dynamicMaxAttackCount $ \case
        PlayerCharacter h -> dynamicMaxAttackCount h
        MinionCharacter h -> dynamicMaxAttackCount h
    getAttackCount = logCall 'getAttackCount $ \case
        PlayerCharacter h -> getAttackCount h
        MinionCharacter h -> getAttackCount h
    bumpAttackCount = logCall 'bumpAttackCount $ \case
        PlayerCharacter h -> bumpAttackCount h
        MinionCharacter h -> bumpAttackCount h
    hasSummoningSickness = logCall 'hasSummoningSickness $ \case
        PlayerCharacter h -> hasSummoningSickness h
        MinionCharacter h -> hasSummoningSickness h


dynamicRemainingHealth :: (HearthMonad m) => CharacterHandle -> Hearth m Health
dynamicRemainingHealth h = do
    damage <- getDamage h
    health <- dynamicMaxHealth h
    return $ health - Health (unDamage damage)


receiveDamage :: (HearthMonad m) => CharacterHandle -> Damage -> Hearth m ()
receiveDamage ch damage = logCall 'receiveDamage $ case damage <= 0 of
    True -> return ()
    False -> case ch of
        PlayerCharacter handle -> do
            bh <- view $ getPlayer handle.playerHero
            let dmg = unDamage damage
                armor = bh^.boardHeroArmor
                armor' = max 0 $ armor - Armor dmg
                armorDamage = Damage $ unArmor $ armor - armor'
                healthDamage = damage - armorDamage
            zoom (getPlayer handle.playerHero) $ do
                boardHeroDamage += healthDamage
                boardHeroArmor .= armor'
            snap <- gets GameSnapshot
            prompt $ PromptGameEvent snap $ HeroTakesDamage handle damage
        MinionCharacter handle -> do
            bm <- view $ getMinion handle
            case loseDivineShield bm of
                Just bm' -> do
                    getMinion handle .= bm'
                    snap <- gets GameSnapshot
                    prompt $ PromptGameEvent snap $ LostDivineShield $ handle
                Nothing -> do
                    let bm' = bm & boardMinionDamage +~ damage
                    getMinion handle .= bm'
                    snap <- gets GameSnapshot
                    prompt $ PromptGameEvent snap $ MinionTakesDamage handle damage


enactKeywordEffect :: (HearthMonad m) => KeywordEffect -> Hearth m ()
enactKeywordEffect = logCall 'enactKeywordEffect . \case
    Silence handle -> silence handle


silence :: (HearthMonad m) => MinionHandle -> Hearth m ()
silence victim = logCall 'silence $ do
    health <- dynamicMaxHealth victim
    zoom (getMinion victim) $ do
        boardMinionAbilities .= []
        boardMinionEnchantments .= []
    health' <- dynamicMaxHealth victim
    getMinion victim %= \bm -> let
        delta = Damage $ unHealth $ health' - health
        in case delta < 0 of
            True -> bm & boardMinionDamage %~ max 0 . (+ delta)
            False -> bm
    snap <- gets GameSnapshot
    prompt $ PromptGameEvent snap $ Silenced victim


data Available a = Available a | NotAvailable
    deriving (Show, Eq, Ord)


type SimplePickResult s = Available (PickResult s ())


class (PickFrom s, Eq (PickResult s ())) => EnactElectionEffect s where
    enactElectionEffect :: (HearthMonad m) => (a -> ElectionEffect s) -> (Available (PickResult s a)) -> Hearth m (SimplePickResult s)
    purePick :: a -> Available (PickResult s a)


instance EnactElectionEffect Targeted where
    enactElectionEffect cont = \case
        NotAvailable -> return NotAvailable
        Available result -> case result of
            TargetedPick choice -> case cont choice of
                Targeted elect -> enactElect elect
                Effect effect -> enactEffect effect
            AbortTargetedPick -> return $ Available AbortTargetedPick
    purePick = Available . TargetedPick


instance EnactElectionEffect AtRandom where
    enactElectionEffect cont = \case
        NotAvailable -> $todo 'enactElectionEffect "xxx"
        Available (AtRandomPick choice) -> case cont choice of
            FromRandom effect -> enactEffect effect
    purePick = Available . AtRandomPick


enactElect :: (HearthMonad m, EnactElectionEffect s) => Elect s -> Hearth m (SimplePickResult s)
enactElect = logCall 'enactElect . \case
    AnyCharacter f -> enactAnyCharacter f
    AnyMinion f -> enactAnyMinion f
    AnyEnemy f -> enactAnyEnemy f
    AnotherCharacter bannedMinion f -> enactAnotherCharacter bannedMinion f
    AnotherMinion bannedMinion f -> enactAnotherMinion bannedMinion f
    AnotherFriendlyMinion bannedMinion f -> enactAnotherFriendlyMinion bannedMinion f


enactAll :: (HearthMonad m, EnactElectionEffect s) => All -> Hearth m (SimplePickResult s)
enactAll = logCall 'enactAll . \case
    OtherCharacters bannedMinion f -> enactOtherCharacters bannedMinion f
    OtherEnemies bannedMinion f -> enactOtherEnemies bannedMinion f
    CharactersOf player f -> enactCharactersOf player f
    MinionsOf player f -> enactMinionsOf player f
    Players f -> enactPlayers f
    Minions f -> enactMinions f
    Characters f -> enactCharacters f


enactUnique :: (HearthMonad m, EnactElectionEffect s) => Unique -> Hearth m (SimplePickResult s)
enactUnique = logCall 'enactUnique . \case
    CasterOf _ f -> getActivePlayerHandle >>= enactEffect . f
    OpponentOf _ f -> getNonActivePlayerHandle >>= enactEffect . f
    ControllerOf minionHandle f -> controllerOf minionHandle >>= enactEffect . f


enactCharacters :: (HearthMonad m, EnactElectionEffect s) => ([CharacterHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactCharacters f = logCall 'enactCharacters $ do
    playerCandidates <- getPlayerHandles
    minionCandidates <- viewListOf $ gamePlayers.traversed.playerMinions.traversed.boardMinionHandle
    let candidates = map PlayerCharacter playerCandidates ++ map MinionCharacter minionCandidates
    enactEffect $ f candidates


enactMinions :: (HearthMonad m, EnactElectionEffect s) => ([MinionHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactMinions f = logCall 'enactMinions $ do
    candidates <- viewListOf $ gamePlayers.traversed.playerMinions.traversed.boardMinionHandle
    enactEffect $ f candidates


enactPlayers :: (HearthMonad m, EnactElectionEffect s) => ([PlayerHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactPlayers f = logCall 'enactPlayers $ do
    candidates <- getPlayerHandles
    enactEffect $ f candidates


enactMinionsOf :: (HearthMonad m, EnactElectionEffect s) => PlayerHandle -> ([MinionHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactMinionsOf player f = logCall 'enactMinionsOf $ do
    candidates <- viewListOf $ getPlayer player.playerMinions.traversed.boardMinionHandle
    enactEffect $ f candidates


enactCharactersOf :: (HearthMonad m, EnactElectionEffect s) => PlayerHandle -> ([CharacterHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactCharactersOf player f = logCall 'enactCharactersOf $ do
    minionCandidates <- viewListOf $ getPlayer player.playerMinions.traversed.boardMinionHandle.to MinionCharacter
    let playerCandidate = PlayerCharacter player
        candidates = playerCandidate : minionCandidates
    enactEffect $ f candidates


enactOtherEnemies :: (HearthMonad m, EnactElectionEffect s) => CharacterHandle -> ([CharacterHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactOtherEnemies bannedHandle f = logCall 'enactOtherEnemies $ do
    opponentHandle <- controllerOf bannedHandle
    minionCandidates <- do
        bms <- view $ getPlayer opponentHandle.playerMinions
        let bmHandles = map (\bm -> bm^.boardMinionHandle) bms
        return $ filter (/= bannedHandle) $ map MinionCharacter bmHandles
    let playerCandidates = filter (/= bannedHandle) [PlayerCharacter opponentHandle]
        candidates = playerCandidates ++ minionCandidates
    enactEffect $ f candidates


enactOtherCharacters :: (HearthMonad m, EnactElectionEffect s) => CharacterHandle -> ([CharacterHandle] -> Effect) -> Hearth m (SimplePickResult s)
enactOtherCharacters bannedHandle f = logCall 'enactOtherCharacters $ do
    pHandles <- getPlayerHandles
    minionCandidates <- liftM concat $ forM pHandles $ \pHandle -> do
        bms <- view $ getPlayer pHandle.playerMinions
        let bmHandles = map (\bm -> bm^.boardMinionHandle) bms
        return $ filter (/= bannedHandle) $ map MinionCharacter bmHandles
    let playerCandidates = filter (/= bannedHandle) $ map PlayerCharacter pHandles
        candidates = playerCandidates ++ minionCandidates
    enactEffect $ f candidates


enactAnotherCharacter :: (HearthMonad m, EnactElectionEffect s) => CharacterHandle -> (CharacterHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnotherCharacter bannedHandle f = logCall 'enactAnotherCharacter $ do
    pHandles <- getPlayerHandles
    minionCandidates <- liftM concat $ forM pHandles $ \pHandle -> do
        bms <- view $ getPlayer pHandle.playerMinions
        let bmHandles = map (\bm -> bm^.boardMinionHandle) bms
        return $ filter (/= bannedHandle) $ map MinionCharacter bmHandles
    let playerCandidates = filter (/= bannedHandle) $ map PlayerCharacter pHandles
        candidates = playerCandidates ++ minionCandidates
    pickFrom candidates >>= enactElectionEffect f


enactAnyEnemy :: (HearthMonad m, EnactElectionEffect s) => (CharacterHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnyEnemy f = logCall 'enactAnyEnemy $ do
    opponentHandle <- getNonActivePlayerHandle
    minionCandidates <- do
        bms <- view $ getPlayer opponentHandle.playerMinions
        return $ map (\bm -> MinionCharacter $ bm^.boardMinionHandle) bms
    let playerCandidates = [PlayerCharacter opponentHandle]
        candidates = playerCandidates ++ minionCandidates
    pickFrom candidates >>= enactElectionEffect f


enactAnyCharacter :: (HearthMonad m, EnactElectionEffect s) => (CharacterHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnyCharacter f = logCall 'enactAnyCharacter $ do
    pHandles <- getPlayerHandles
    minionCandidates <- liftM concat $ forM pHandles $ \pHandle -> do
        bms <- view $ getPlayer pHandle.playerMinions
        return $ map (\bm -> MinionCharacter $ bm^.boardMinionHandle) bms
    let playerCandidates = map PlayerCharacter pHandles
        candidates = playerCandidates ++ minionCandidates
    pickFrom candidates >>= enactElectionEffect f


enactAnyMinion :: (HearthMonad m, EnactElectionEffect s) => (MinionHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnyMinion f = logCall 'enactAnyMinion $ do
    pHandles <- getPlayerHandles
    candidates <- liftM concat $ forM pHandles $ \pHandle -> do
        bms <- view $ getPlayer pHandle.playerMinions
        return $ map (\bm -> bm^.boardMinionHandle) bms
    pickFrom candidates >>= enactElectionEffect f


enactAnotherMinion :: (HearthMonad m, EnactElectionEffect s) => MinionHandle -> (MinionHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnotherMinion bannedHandle f = logCall 'enactAnotherMinion $ do
    handles <- getPlayerHandles
    candidates <- liftM concat $ forM handles $ \handle -> do
        bms <- view $ getPlayer handle.playerMinions
        let bmHandles = map (\bm -> bm^.boardMinionHandle) bms
        return $ filter (/= bannedHandle) bmHandles
    pickFrom candidates >>= enactElectionEffect f


enactAnotherFriendlyMinion :: (HearthMonad m, EnactElectionEffect s) => MinionHandle -> (MinionHandle -> ElectionEffect s) -> Hearth m (SimplePickResult s)
enactAnotherFriendlyMinion bannedHandle f = logCall 'enactAnotherFriendlyMinion $ do
    controller <- controllerOf bannedHandle
    candidates <- do
        bms <- view $ getPlayer controller.playerMinions
        let bmHandles = map (\bm -> bm^.boardMinionHandle) bms
        return $ filter (/= bannedHandle) bmHandles
    pickFrom candidates >>= enactElectionEffect f


class (Eq a) => Pickable s a where
    promptPick :: GameSnapshot -> NonEmpty a -> PromptPick s a
    pickFailError :: Proxy (s, a) -> HearthError


instance Pickable s MinionHandle where
    promptPick = PickMinion
    pickFailError _ = InvalidMinion


instance Pickable s PlayerHandle where
    promptPick = PickPlayer
    pickFailError _ = InvalidPlayer


instance Pickable s CharacterHandle where
    promptPick = PickCharacter
    pickFailError _ = InvalidCharacter


class PickFrom s where
    pickFrom :: forall m a. (HearthMonad m, Pickable s a) => [a] -> Hearth m (Available (PickResult s a))


instance PickFrom AtRandom where
    pickFrom :: forall m a. (HearthMonad m, Pickable AtRandom a) => [a] -> Hearth m (Available (PickResult AtRandom a))
    pickFrom = logCall 'pickFrom . \case
        [] -> return NotAvailable
        xs -> liftM Available $ do
            snapshot <- gets GameSnapshot
            guardedPrompt (PromptPickAtRandom $ promptPick snapshot $ NonEmpty.fromList xs) $ \case
                AtRandomPick x -> case x `elem` xs of
                    True -> return True
                    False -> do
                        prompt $ PromptError $ pickFailError (Proxy :: Proxy (AtRandom, a))
                        return False


instance PickFrom Targeted where
    pickFrom :: forall m a. (HearthMonad m, Pickable Targeted a) => [a] -> Hearth m (Available (PickResult Targeted a))
    pickFrom = logCall 'pickFrom . \case
        [] -> return NotAvailable
        xs -> liftM Available $ do
            snapshot <- gets GameSnapshot
            guardedPrompt (PromptPickTargeted $ promptPick snapshot $ NonEmpty.fromList xs) $ \case
                AbortTargetedPick -> return True
                TargetedPick x -> case x `elem` xs of
                    True -> return True
                    False -> do
                        prompt $ PromptError $ pickFailError (Proxy :: Proxy (Targeted, a))
                        return False


playCommon :: (HearthMonad m) => PlayerHandle -> HandCard -> Hearth m Result
playCommon handle card = logCall 'playCommon $ removeFromHand handle card >>= \case
    False -> return Failure
    True -> payCost handle $ costOf card


costOf :: HandCard -> Cost
costOf = \case
    HandCardMinion minion -> minion^.minionCost
    HandCardSpell spell -> spell^.spellCost


payCost :: (HearthMonad m) => PlayerHandle -> Cost -> Hearth m Result
payCost who = logCall 'payCost $  \case
    ManaCost mana -> payManaCost who mana


payManaCost :: (HearthMonad m) => PlayerHandle -> Mana -> Hearth m Result
payManaCost who (Mana cost) = logCall 'payManaCost $ zoom (getPlayer who) $ do
    totalMana <- view playerTotalManaCrystals
    emptyMana <- view playerEmptyManaCrystals
    let availableMana = totalMana - emptyMana
    case cost <= availableMana of
        False -> return Failure
        True -> do
            playerEmptyManaCrystals += cost
            return Success


clearDeadMinions :: (HearthMonad m) => Hearth m ()
clearDeadMinions = logCall 'clearDeadMinions $ do
    snap <- gets GameSnapshot
    minions <- viewListOf $ gamePlayers.traversed.playerMinions.traversed.boardMinionHandle
    let _ = minions :: [MinionHandle]
    forM_ minions $ \minion -> do
        dead <- isDead $ MinionCharacter minion
        when dead $ do
            prompt $ PromptGameEvent snap $ MinionDied minion
            enactAnyDeathrattles minion
            removeMinion minion


removeMinion :: (HearthMonad m) => MinionHandle -> Hearth m ()
removeMinion minion = do
    controller <- controllerOf minion
    getPlayer controller.playerMinions %= filter (\bm -> bm^.boardMinionHandle /= minion)


dynamicHasAbility :: (HearthMonad m) => (Ability -> Bool) -> MinionHandle -> Hearth m Bool
dynamicHasAbility predicate bmHandle = logCall 'dynamicHasAbility $ do
    abilities <- dynamicAbilities bmHandle
    return $ any predicate abilities


dynamicHasTaunt :: (HearthMonad m) => MinionHandle -> Hearth m Bool
dynamicHasTaunt = logCall 'dynamicHasTaunt $ dynamicHasAbility $ \case
    KeywordAbility Taunt -> True
    _ -> False


dynamicHasCharge :: (HearthMonad m) => MinionHandle -> Hearth m Bool
dynamicHasCharge = logCall 'dynamicHasCharge $ dynamicHasAbility $ \case
    KeywordAbility Charge -> True
    _ -> False


hasTauntMinions :: (HearthMonad m) => PlayerHandle -> Hearth m Bool
hasTauntMinions player = logCall 'hasTauntMinions $ do
    view (getPlayer player.playerMinions) >>= anyM (dynamicHasTaunt . _boardMinionHandle)


isAlly :: (Controllable a, HearthMonad m) => a -> Hearth m Bool
isAlly bm = do
    controller <- controllerOf bm
    active <- getActivePlayerHandle
    return $ controller == active


isEnemy :: (Controllable a, HearthMonad m) => a -> Hearth m Bool
isEnemy = liftM not . isAlly


hasRemainingAttacks :: (CharacterTraits a, HearthMonad m) => a -> Hearth m Bool
hasRemainingAttacks c = liftM2 (<) (getAttackCount c) (dynamicMaxAttackCount c)


enactAttack :: (HearthMonad m) => CharacterHandle -> CharacterHandle -> Hearth m Result
enactAttack attacker defender = logCall 'enactAttack $ do
    snap <- gets GameSnapshot
    let promptGameEvent = PromptGameEvent snap
        attackerHandle = characterHandle attacker
        defenderHandle = characterHandle defender
        defenderHasTaunt = case defender of
            PlayerCharacter _ -> return False
            MinionCharacter m -> dynamicHasTaunt m
    result <- isAlly attacker >>= \case
        False -> do
            prompt $ promptGameEvent $ AttackFailed AttackWithEnemy
            return Failure
        True -> do
            attack <- dynamicAttack attacker
            case attack <= 0 of
                True -> do
                    prompt $ promptGameEvent $ AttackFailed ZeroAttack
                    return Failure
                False -> isEnemy defender >>= \case
                    False -> do
                        prompt $ promptGameEvent $ AttackFailed DefendWithFriendly
                        return Failure
                    True -> hasSummoningSickness attacker >>= \case
                        True -> do
                            prompt $ promptGameEvent $ AttackFailed DoesNotHaveCharge
                            return Failure
                        False -> hasRemainingAttacks attacker >>= \case
                            False -> do
                                prompt $ promptGameEvent $ AttackFailed OutOfAttacks
                                return Failure
                            True -> defenderHasTaunt >>= \case
                                True -> return Success
                                False -> do
                                    defenderController <- controllerOf defender
                                    hasTauntMinions defenderController >>= \case
                                        True -> do
                                            prompt $ promptGameEvent $ AttackFailed TauntsExist
                                            return Failure
                                        False -> return Success
    case result of
        Failure -> return Failure
        Success -> do
            prompt $ promptGameEvent $ EnactAttack attackerHandle defenderHandle
            let x `harms` y = do
                    dmg <- liftM (Damage . unAttack) $ dynamicAttack x
                    receiveDamage (characterHandle y) dmg
            attacker `harms` defender
            defender `harms` attacker
            bumpAttackCount attacker
            return Success


replaceMinionByHandle :: (HearthMonad m) => BoardMinion -> Hearth m ()
replaceMinionByHandle bm' = logCall 'replaceMinionByHandle $ do
    controller <- controllerOf $ bm'^.boardMinionHandle
    getPlayer controller.playerMinions %= \bms -> let
        (front, _ : end) = span (\bm -> bm^.boardMinionHandle /= bm'^.boardMinionHandle) bms
        in front ++ [bm'] ++ end
    

loseDivineShield :: BoardMinion -> Maybe BoardMinion
loseDivineShield bm = let
    abilities = bm^.boardMinionAbilities
    abilities' = flip filter abilities $ \case
        KeywordAbility DivineShield -> False
        _ -> True
    in case on (==) length abilities abilities' of
        True -> Nothing
        False -> Just $ bm & boardMinionAbilities .~ abilities'





























































