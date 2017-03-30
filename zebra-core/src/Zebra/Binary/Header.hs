{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
module Zebra.Binary.Header (
    Header(..)
  , BinaryVersion(..)

  , headerOfAttributes
  , attributesOfHeader
  , schemaOfHeader

  , bHeader
  , bVersion

  , getHeader
  , getVersion

  -- * Internal
  , bHeaderV3
  , getHeaderV3

  , bHeaderV2
  , getHeaderV2
  ) where

import           Data.Binary.Get (Get)
import qualified Data.Binary.Get as Get
import           Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import           Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as Builder
import           Data.Map (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as Boxed

import           P

import           Zebra.Binary.Array
import           Zebra.Data.Block
import           Zebra.Data.Core
import           Zebra.Json.Codec
import           Zebra.Json.Schema
import           Zebra.Schema (TableSchema, ColumnSchema)
import qualified Zebra.Schema as Schema


data Header =
    HeaderV2 !(Map AttributeName ColumnSchema)
  | HeaderV3 !TableSchema
    deriving (Eq, Ord, Show)

data BinaryVersion =
--  BinaryV0 -- x Initial version.
--  BinaryV1 -- x Store factset-id instead of priority, this flips sort order.
    BinaryV2 -- ^ Schema is stored in header, instead of encoding.
  | BinaryV3 -- ^ Data is stored as tables instead of entity blocks.
    deriving (Eq, Ord, Show)

headerOfAttributes :: BinaryVersion -> Map AttributeName ColumnSchema -> Header
headerOfAttributes version attributes =
  case version of
    BinaryV2 ->
      HeaderV2 attributes
    BinaryV3 ->
      HeaderV3 (tableSchemaOfAttributes attributes)

attributesOfHeader :: Header -> Either BlockTableError (Map AttributeName ColumnSchema)
attributesOfHeader = \case
  HeaderV2 attributes ->
    pure attributes
  HeaderV3 table ->
    attributesOfTableSchema table

schemaOfHeader :: Header -> TableSchema
schemaOfHeader = \case
  HeaderV2 attributes ->
    tableSchemaOfAttributes attributes
  HeaderV3 table ->
    table

-- | Encode a zebra header.
--
--   header {
--     "||ZEBRA||vvvvv||" : 16 x u8
--     header             : header_v2 | header_v3
--   }
--
bHeader :: Header -> Builder
bHeader = \case
  HeaderV2 x ->
    bVersion BinaryV2 <>
    bHeaderV2 x
  HeaderV3 x ->
    bVersion BinaryV3 <>
    bHeaderV3 x

getHeader :: Get Header
getHeader = do
  version <- getVersion
  case version of
    BinaryV2 ->
      HeaderV2 <$> getHeaderV2
    BinaryV3 ->
      HeaderV3 <$> getHeaderV3

-- | Encode a zebra v3 header from a dictionary.
--
-- @
--   header_v3 {
--     schema : sized_byte_array
--   }
-- @
bHeaderV3 :: TableSchema -> Builder
bHeaderV3 schema =
  bSizedByteArray (encodeSchema JsonV0 schema)

getHeaderV3 :: Get TableSchema
getHeaderV3 =
  parseSchema =<< getSizedByteArray

-- | Encode a zebra v2 header from a dictionary.
--
-- @
--   header_v2 {
--     attr_count         : u32
--     attr_name_length   : int_array schema_count
--     attr_name_string   : sized_byte_array
--     attr_schema_length : int_array schema_count
--     attr_schema_string : sized_byte_array
--   }
-- @
bHeaderV2 :: Map AttributeName ColumnSchema -> Builder
bHeaderV2 features =
  let
    n_attrs =
      Builder.word32LE . fromIntegral $
      Map.size features

    names =
      bStrings .
      fmap (Text.encodeUtf8 . unAttributeName) .
      Boxed.fromList $
      Map.keys features

    schema =
      bStrings .
      fmap (encodeSchema JsonV0 . Schema.Array) .
      Boxed.fromList $
      Map.elems features
  in
    n_attrs <>
    names <>
    schema

getHeaderV2 :: Get (Map AttributeName ColumnSchema)
getHeaderV2 = do
  n <- fromIntegral <$> Get.getWord32le
  ns <- fmap (AttributeName . Text.decodeUtf8) <$> getStrings n
  ts <- traverse parseSchema =<< getStrings n

  let
    cs =
      either (fail . Text.unpack . Schema.renderSchemaError) id $
      traverse Schema.takeArray ts

  pure .
    Map.fromList . toList $
    Boxed.zip ns cs

parseSchema :: ByteString -> Get TableSchema
parseSchema =
  either (fail . Text.unpack . renderJsonDecodeError) pure . decodeSchema JsonV0

-- | The zebra 8-byte magic number, including version.
--
-- @
-- ||ZEBRA||vvvvv||
-- @
bVersion :: BinaryVersion -> Builder
bVersion = \case
  BinaryV2 ->
    Builder.byteString MagicV2
  BinaryV3 ->
    Builder.byteString MagicV3

getVersion :: Get BinaryVersion
getVersion = do
  bs <- Get.getByteString $ ByteString.length MagicV2
  case bs of
    MagicV0 ->
      fail $ "This version of zebra cannot read v0 zebra files."
    MagicV1 ->
      fail $ "This version of zebra cannot read v1 zebra files."
    MagicV2 ->
      pure BinaryV2
    MagicV3 ->
      pure BinaryV3
    _ ->
      fail $ "Invalid/unknown file signature: " <> show bs

#if __GLASGOW_HASKELL__ >= 800
pattern MagicV0 :: ByteString
#endif
pattern MagicV0 =
  "||ZEBRA||00000||"

#if __GLASGOW_HASKELL__ >= 800
pattern MagicV1 :: ByteString
#endif
pattern MagicV1 =
  "||ZEBRA||00001||"

#if __GLASGOW_HASKELL__ >= 800
pattern MagicV2 :: ByteString
#endif
pattern MagicV2 =
  "||ZEBRA||00002||"

#if __GLASGOW_HASKELL__ >= 800
pattern MagicV3 :: ByteString
#endif
pattern MagicV3 =
  "||ZEBRA||00003||"
