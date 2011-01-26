module GameState where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Internal as I
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Foldable (for_)
import Data.List (foldl')
import qualified Data.Map as Map
import Data.Int
import Data.Word
import Data.Bits
import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Storable
import qualified Data.Vector as V
import Data.Vector (Vector)

import Protocol
import JavaBinary

type EntityMap = Map EntityId (Either String MobId, Int32, Int32, Int32)

type BlockMap  = Map (Int32, Int32) (Vector BlockId)

data GameState = GS
  { entityMap :: !EntityMap 
  , blockMap  :: !BlockMap
  , health    :: Int16
  , time      :: Maybe Int64
  , spawnLocation :: Maybe (Int32, Int32, Int32)
  }

newGameState = GS Map.empty Map.empty 19 Nothing Nothing

updateEntityMap :: (EntityMap -> EntityMap)
                -> GameState -> GameState
updateEntityMap f gs = gs { entityMap = f (entityMap gs) }


updateBlockMap :: (BlockMap -> BlockMap)
               -> GameState -> GameState
updateBlockMap f gs = gs { blockMap = f (blockMap gs) }


updateHealth :: (Int16 -> Int16)
               -> GameState -> GameState
updateHealth f gs = gs { health = f (health gs) }


updateGameState :: Message -> GameState -> (Maybe EntityId, GameState)

updateGameState (NamedEntitySpawn eid name x y z _ _ _) gs
  = (Just eid, updateEntityMap (Map.insert eid (Left name, x, y, z)) gs)

updateGameState (MobSpawn eid ty x y z _ _ _) gs
  = (Just eid, updateEntityMap (Map.insert eid (Right ty, x, y, z)) gs)

updateGameState (EntityTeleport eid x y z _ _) gs
  = (Just eid,
     updateEntityMap (Map.update (\ (ty,_,_,_) -> Just (ty, x, y, z)) eid) gs)

updateGameState (EntityRelativeMove eid dX dY dZ) gs
  = (Just eid, gs')
  where
   gs' = updateEntityMap (Map.update aux eid) gs
   aux (ty,x,y,z) = x' `seq` y' `seq` z' `seq` Just (ty, x', y', z')
          where x' = x + fromIntegral dX
                y' = y + fromIntegral dY
                z' = z + fromIntegral dZ

updateGameState (EntityLookMove eid dX dY dZ _ _) gs
  = (Just eid, updateEntityMap (Map.update aux eid) gs)
  where aux (ty,x,y,z) = Just (ty, x + fromIntegral dX,
                                   y + fromIntegral dY,
                                   z + fromIntegral dZ)

updateGameState (DestroyEntity eid) gs
  = (Just eid, updateEntityMap (Map.delete eid) gs)

updateGameState (UpdateHealth x) gs
  = (Nothing, gs { health = x })

updateGameState (SpawnPosition x y z) gs
  = (Nothing, gs { spawnLocation = Just (x,y,z) })

updateGameState (TimeUpdate t) gs
  = (Nothing, gs { time = Just t })

updateGameState (Mapchunk x y z sx sy sz bs ms b c) gs
  = (Nothing, updateBlockMap (setChunk x y z sx sy sz bs ms) gs)

updateGameState (MultiblockChange x z changes) gs
  = (Nothing, updateBlockMap (setBlocks x z changes) gs)

updateGameState (Prechunk x z False) gs
  = (Nothing, updateBlockMap (Map.delete (x,z)) gs)

updateGameState (BlockChange x y z blockid meta) gs
  = (Nothing, updateBlockMap (setBlock x y z blockid meta) gs)

updateGameState _ gs = (Nothing, gs)


decomposeCoords :: Int32 -> Int32 -> Int32 -> ((Int32, Int32), (Int8, Int8, Int8))
decomposeCoords x y z = ((x `shiftR` 4
                        ,z `shiftR` 4)
                        ,(fromIntegral $ x .&. 0xf
                        ,fromIntegral $ y .&. 0x7f
                        ,fromIntegral $ z .&. 0xf)
                        )

packCoords :: (Int8,Int8,Int8) -> Int
packCoords (x,y,z) = fromIntegral x `shiftL` 12 .|. fromIntegral z `shiftL` 8 .|. fromIntegral y

setChunk x y z sx sy sz bs ms bm = Map.alter
  (\x -> Just $! (fromMaybe newVec x) V.// (zip coords bs))
  chunk
  bm
  where
  (chunk,(bx,by,bz)) = decomposeCoords x (fromIntegral y) z
  coords = do x <- take (fromIntegral sx + 1) [bx ..]
              z <- take (fromIntegral sz + 1) [bz ..]
              y <- take (fromIntegral sy + 1) [by ..]
              return $ packCoords (x,y,z)


setBlocks x z changes = Map.alter (\ x -> Just $! (fromMaybe newVec x) V.// map aux changes) (x,z)
  where
  splitCoord c = (fromIntegral $ c `shiftR` 12, fromIntegral $ c .&. 0x7f, fromIntegral $ (c `shiftR` 8) .&. 0xf)
  aux (coord, ty, meta) = (fromIntegral (fromIntegral coord :: Word16), ty)

setBlock :: Int32 -> Int8 -> Int32 -> BlockId -> Int8 -> BlockMap -> BlockMap
setBlock x y z blockid meta = Map.alter
  (\ x -> Just $! (fromMaybe newVec x) V.// [(packCoords block, blockid)] )
  chunk
  where
  (chunk,block) = decomposeCoords x (fromIntegral y) z

newVec = V.replicate (16*16*256) Air