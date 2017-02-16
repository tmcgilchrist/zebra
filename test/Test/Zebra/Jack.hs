{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
module Test.Zebra.Jack (
  -- * Zebra.Data.Block
    jBlock

  , jYoloBlock
  , jBlockEntity
  , jBlockAttribute
  , jBlockIndex
  , jTombstone

  -- * Zebra.Data.Core
  , jEntityId
  , jEntityHashId
  , jAttributeId
  , jAttributeName
  , jTime
  , jDay
  , jFactsetId

  -- * Zebra.Data.Schema
  , jSchema
  , jFieldSchema
  , jFieldName
  , jVariantSchema
  , jVariantName

  -- * Zebra.Data.Entity
  , jEntity
  , jAttribute

  -- * Zebra.Data.Fact
  , jFacts
  , jFact
  , jValue

  -- * Zebra.Data.Table
  , jTable
  , jTable'
  , jColumn

  -- * Zebra.Data.Encoding
  , jEncoding
  , jColumnEncoding

  , jMaybe'
  ) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as Char8
import qualified Data.List as List
import           Data.Thyme.Calendar (Year, Day, YearMonthDay(..), gregorianValid)
import qualified Data.Vector as Boxed
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Unboxed as Unboxed

import           Disorder.Corpus (muppets, southpark, boats, weather)
import           Disorder.Jack (Jack, mkJack, reshrink, shrinkTowards, sized, scale)
import           Disorder.Jack (elements, arbitrary, choose, chooseInt, sizedBounded)
import           Disorder.Jack (oneOf, oneOfRec, listOf, listOfN, vectorOf, justOf, maybeOf)

import           P

import qualified Prelude as Savage

import qualified Test.QuickCheck as QC
import           Test.QuickCheck.Instances ()

import           Text.Printf (printf)

import           Zebra.Data.Block
import           Zebra.Data.Core
import           Zebra.Data.Encoding
import           Zebra.Data.Entity
import           Zebra.Data.Fact
import           Zebra.Data.Schema
import           Zebra.Data.Table


jEncoding :: Jack Encoding
jEncoding =
  Encoding <$> listOf jColumnEncoding

jColumnEncoding :: Jack ColumnEncoding
jColumnEncoding =
  oneOfRec [
      pure IntEncoding
    , pure ByteEncoding
    , pure DoubleEncoding
    ] [
      ArrayEncoding <$> jEncoding
    ]

schemaSubterms :: Schema -> [Schema]
schemaSubterms = \case
  BoolSchema ->
    []
  Int64Schema ->
    []
  DoubleSchema ->
    []
  StringSchema ->
    []
  DateSchema ->
    []
  ListSchema s ->
    [s]
  StructSchema ss ->
    fmap fieldSchema $ Boxed.toList ss
  EnumSchema s0 ss ->
    fmap variantSchema $ s0 : Boxed.toList ss

jSchema :: Jack Schema
jSchema =
  reshrink schemaSubterms $
  oneOfRec [
      pure BoolSchema
    , pure Int64Schema
    , pure DoubleSchema
    , pure StringSchema
    , pure DateSchema
    ] [
      ListSchema <$> jSchema
    , StructSchema . Boxed.fromList <$> listOfN 0 10 jFieldSchema
    , EnumSchema <$> jVariantSchema <*> (Boxed.fromList <$> listOfN 0 9 jVariantSchema)
    ]

jFieldSchema :: Jack FieldSchema
jFieldSchema =
  FieldSchema <$> jFieldName <*> jSchema

jFieldName :: Jack FieldName
jFieldName =
  FieldName <$> elements boats

jVariantSchema :: Jack VariantSchema
jVariantSchema =
  VariantSchema <$> jVariantName <*> jSchema

jVariantName :: Jack VariantName
jVariantName =
  VariantName <$> elements weather

jFacts :: [Schema] -> Jack [Fact]
jFacts schemas =
  fmap (List.sort . List.concat) .
  scale (`div` max 1 (length schemas)) $
  zipWithM (\e a -> listOf $ jFact e a) schemas (fmap AttributeId [0..])

jFact :: Schema -> AttributeId -> Jack Fact
jFact schema aid =
  uncurry Fact
    <$> jEntityHashId
    <*> pure aid
    <*> jTime
    <*> jFactsetId
    <*> (strictMaybe <$> maybeOf (jValue schema))

jValue :: Schema -> Jack Value
jValue = \case
  BoolSchema ->
    BoolValue <$> elements [False, True]
  Int64Schema ->
    Int64Value <$> sizedBounded
  DoubleSchema ->
    DoubleValue <$> arbitrary
  StringSchema ->
    StringValue <$> arbitrary
  DateSchema ->
    DateValue <$> jDay
  ListSchema schema ->
    ListValue . Boxed.fromList <$> listOfN 0 10 (jValue schema)
  StructSchema fields ->
    StructValue <$> traverse (jValue . fieldSchema) fields
  EnumSchema variant0 variants -> do
    tag <- choose (0, Boxed.length variants)
    case tag of
      0 ->
        EnumValue tag <$> jValue (variantSchema variant0)
      _ ->
        EnumValue tag <$> jValue (variantSchema $ variants Boxed.! (tag - 1))

jEntityId :: Jack EntityId
jEntityId =
  let
    mkEnt name num =
      EntityId $ name <> Char8.pack (printf "-%03d" num)
  in
    mkEnt
      <$> elements southpark
      <*> chooseInt (0, 999)

jAttributeId :: Jack AttributeId
jAttributeId =
  AttributeId <$> choose (0, 10000)

jAttributeName :: Jack AttributeName
jAttributeName =
  AttributeName <$> oneOf [elements muppets, arbitrary]

jTime :: Jack Time
jTime =
  fromDay <$> jDay

jDay :: Jack Day
jDay =
  justOf . fmap gregorianValid $
    YearMonthDay
      <$> jYear
      <*> chooseInt (1, 12)
      <*> chooseInt (1, 31)

jYear :: Jack Year
jYear =
  mkJack (shrinkTowards 2000) $ QC.choose (1600, 3000)

jFactsetId :: Jack FactsetId
jFactsetId =
  FactsetId <$> choose (0, 100000)

jBlock :: Jack Block
jBlock = do
  schemas <- listOfN 0 5 jSchema
  facts <- jFacts schemas
  pure $
    case blockOfFacts (Boxed.fromList schemas) (Boxed.fromList facts) of
      Left x ->
        Savage.error $ "Test.Zebra.Jack.jBlock: invariant failed: " <> show x
      Right x ->
        x

-- The blocks generated by this can contain data with broken invariants.
jYoloBlock :: Jack Block
jYoloBlock = do
  Block
    <$> (Boxed.fromList <$> listOf jBlockEntity)
    <*> (Unboxed.fromList <$> listOf jBlockIndex)
    <*> (Boxed.fromList <$> listOf jTable)

jEntityHashId :: Jack (EntityHash, EntityId)
jEntityHashId =
  let
    hash eid =
      EntityHash $ unEntityHash (hashEntityId eid) `mod` 10
  in
    (\eid -> (hash eid, eid)) <$> jEntityId

jBlockEntity :: Jack BlockEntity
jBlockEntity =
  uncurry BlockEntity
    <$> jEntityHashId
    <*> (Unboxed.fromList <$> listOf jBlockAttribute)

jBlockAttribute :: Jack BlockAttribute
jBlockAttribute =
  BlockAttribute
    <$> jAttributeId
    <*> choose (0, 1000000)

jBlockIndex :: Jack BlockIndex
jBlockIndex =
  BlockIndex
    <$> jTime
    <*> jFactsetId
    <*> jTombstone

jEntity :: Jack Entity
jEntity =
  uncurry Entity
    <$> jEntityHashId
    <*> (Boxed.fromList <$> listOf jAttribute)

jAttribute :: Jack Attribute
jAttribute = do
  (ts, ps, bs) <- List.unzip3 <$> listOf ((,,) <$> jTime <*> jFactsetId <*> jTombstone)
  Attribute
    <$> pure (Storable.fromList ts)
    <*> pure (Storable.fromList ps)
    <*> pure (Storable.fromList bs)
    <*> jTable' (List.length ts)

jTombstone :: Jack Tombstone
jTombstone =
  elements [
      NotTombstone
    , Tombstone
    ]

jTable :: Jack Table
jTable =
  sized $ \size -> do
    n <- chooseInt (0, size)
    jTable' n

jTable' :: Int -> Jack Table
jTable' n =
  sized $ \size ->
    Table n . Boxed.fromList <$> listOfN 1 (max 1 (size `div` 10)) (jColumn n)

jColumn :: Int -> Jack Column
jColumn n =
  oneOfRec [
      ByteColumn . B.pack <$> vectorOf n arbitrary
    , IntColumn . Storable.fromList <$> vectorOf n arbitrary
    , DoubleColumn . Storable.fromList <$> vectorOf n arbitrary
    ] [
      sized $ \m -> do
        ms <- vectorOf n $ chooseInt (0, m `div` 10)
        ArrayColumn (Storable.fromList . fmap fromIntegral $ ms) <$> jTable' (sum ms)
    ]

jMaybe' :: Jack a -> Jack (Maybe' a)
jMaybe' j =
  oneOfRec [ pure Nothing' ] [ Just' <$> j ]

