{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Zebra.Foreign.Merge (
    mergeEntity
  , CMergeMany(..)
  , mergeManyInit
  , mergeManyPush
  , mergeManyPop
  , mergeManyClone
  ) where

import           Anemone.Foreign.Mempool (Mempool)
import qualified Anemone.Foreign.Mempool as Mempool

import           Control.Monad.IO.Class (MonadIO(..))

import           Data.Coerce (coerce)
import qualified Data.Vector.Storable as Storable

import           Foreign.Ptr (Ptr, nullPtr)
import           Foreign.Storable (Storable(..))
import           Foreign.ForeignPtr (ForeignPtr, withForeignPtr)

import           P

import           X.Control.Monad.Trans.Either (EitherT)

import           Zebra.Foreign.Bindings
import           Zebra.Foreign.Entity
import           Zebra.Foreign.Util

mergeEntity :: MonadIO m => Mempool -> CEntity -> CEntity -> EitherT ForeignError m CEntity
mergeEntity pool (CEntity c_entity1) (CEntity c_entity2) = do
  merge_into <- liftIO $ Mempool.alloc pool
  liftCError $ c'zebra_merge_entity pool c_entity1 c_entity2 merge_into
  return $ CEntity merge_into

newtype CMergeMany =
  CMergeMany {
      unCMergeMany :: Ptr C'zebra_merge_many
    }
  deriving Storable


mergeManyInit :: MonadIO m => Mempool -> EitherT ForeignError m CMergeMany
mergeManyInit pool = allocStack $ \pmerge -> do
  liftCError $ c'zebra_mm_init pool pmerge
  CMergeMany <$> liftIO (peek pmerge)

mergeManyPush :: MonadIO m => Mempool -> CMergeMany -> Storable.Vector CEntity -> EitherT ForeignError m ()
mergeManyPush pool (CMergeMany merger) entities = do
  let (ptr, len) = Storable.unsafeToForeignPtr0 entities
  let ptr' :: ForeignPtr C'zebra_entity = coerce ptr
  let len' :: Int64 = fromIntegral $ len
  liftCError $ withForeignPtr ptr' $ c'zebra_mm_push pool merger len'

mergeManyPop :: MonadIO m => CMergeMany -> EitherT ForeignError m (Maybe CEntity)
mergeManyPop (CMergeMany merger) = allocStack $ \pentity -> do
  liftCError $ c'zebra_mm_pop merger pentity
  entity <- liftIO $ peek pentity
  if entity == nullPtr
    then return Nothing
    else return $ Just $ CEntity entity

mergeManyClone :: MonadIO m => Mempool -> CMergeMany -> EitherT ForeignError m CMergeMany
mergeManyClone pool (CMergeMany merger) = allocStack $ \pmerge -> do
  liftIO $ poke pmerge merger
  liftCError $ c'zebra_mm_clone pool pmerge
  CMergeMany <$> liftIO (peek pmerge)

