{-# LANGUAGE DeriveDataTypeable #-}


module Hearth.Names.Hero where


--------------------------------------------------------------------------------


import Data.Data


--------------------------------------------------------------------------------


data BasicHeroName
    = Malfurion
    | Rexxar
    | Jaina
    | Uther
    | Anduin
    | Valeera
    | Thrall
    | Gul'dan
    | Garrosh
    deriving (Show, Eq, Ord, Data, Typeable)





