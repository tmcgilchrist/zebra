{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Zebra.Serial.Json.Schema (
    SchemaVersion(..)
  , encodeSchema
  , decodeSchema
  , ppTableSchema

  , JsonSchemaDecodeError(..)
  , renderJsonSchemaDecodeError

  -- * V0
  , pTableSchemaV0
  , pColumnSchemaV0
  , ppTableSchemaV0
  , ppColumnSchemaV0

  -- * V1
  , pTableSchemaV1
  , pColumnSchemaV1
  , ppTableSchemaV1
  , ppColumnSchemaV1
  ) where

import           Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson
import           Data.ByteString (ByteString)

import           P

import qualified X.Data.Vector as Boxed
import           X.Data.Vector.Cons (Cons)
import qualified X.Data.Vector.Cons as Cons

import           Zebra.Serial.Json.Util
import           Zebra.Table.Data
import qualified Zebra.Table.Encoding as Encoding
import qualified Zebra.Table.Schema as Schema


data SchemaVersion =
    SchemaV0
  | SchemaV1
    deriving (Eq, Show, Enum, Bounded)

data JsonSchemaDecodeError =
    JsonSchemaDecodeError !JsonDecodeError
    deriving (Eq, Show)

renderJsonSchemaDecodeError :: JsonSchemaDecodeError -> Text
renderJsonSchemaDecodeError = \case
  JsonSchemaDecodeError err ->
    renderJsonDecodeError err

encodeSchema :: SchemaVersion -> Schema.Table -> ByteString
encodeSchema version =
  encodeJson ["key", "name"] . ppTableSchema version
{-# INLINABLE encodeSchema #-}

decodeSchema :: SchemaVersion -> ByteString -> Either JsonSchemaDecodeError Schema.Table
decodeSchema = \case
  SchemaV0 ->
    first JsonSchemaDecodeError . decodeJson pTableSchemaV0
  SchemaV1 ->
    first JsonSchemaDecodeError . decodeJson pTableSchemaV1
{-# INLINABLE decodeSchema #-}

ppTableSchema :: SchemaVersion -> Schema.Table -> Aeson.Value
ppTableSchema = \case
  SchemaV0 ->
    ppTableSchemaV0
  SchemaV1 ->
    ppTableSchemaV1
{-# INLINABLE ppTableSchema #-}

------------------------------------------------------------------------
-- v0

pTableSchemaV0 :: Aeson.Value -> Aeson.Parser Schema.Table
pTableSchemaV0 =
  pEnum $ \case
    "binary" ->
      pure . const . pure $
        Schema.Binary DenyDefault Encoding.Binary
    "array" ->
      pure . Aeson.withObject "object containing array schema" $ \o ->
        Schema.Array DenyDefault
          <$> withStructField "element" o pColumnSchemaV0
    "map" ->
      pure . Aeson.withObject "object containing map schema" $ \o ->
        Schema.Map DenyDefault
          <$> withStructField "key" o pColumnSchemaV0
          <*> withStructField "value" o pColumnSchemaV0
    _ ->
      Nothing
{-# INLINABLE pTableSchemaV0 #-}

ppTableSchemaV0 :: Schema.Table -> Aeson.Value
ppTableSchemaV0 = \case
  Schema.Binary _def _encoding ->
    ppEnum $ Variant "binary" ppUnit
  Schema.Array _def e ->
    ppEnum . Variant "array" $
      Aeson.object ["element" .= ppColumnSchemaV0 e]
  Schema.Map _def k v ->
    ppEnum . Variant "map" $
      Aeson.object ["key" .= ppColumnSchemaV0 k, "value" .= ppColumnSchemaV0 v]
{-# INLINABLE ppTableSchemaV0 #-}

pColumnSchemaV0 :: Aeson.Value -> Aeson.Parser Schema.Column
pColumnSchemaV0 =
  pEnum $ \case
    "unit" ->
      pure . const $ pure Schema.Unit
    "int" ->
      pure . const . pure $ Schema.Int DenyDefault Encoding.Int
    "double" ->
      pure . const . pure $ Schema.Double DenyDefault
    "enum" ->
      pure . Aeson.withObject "object containing enum column schema" $ \o ->
        Schema.Enum DenyDefault <$> withStructField "variants" o pSchemaEnumVariantsV0
    "struct" ->
      pure . Aeson.withObject "object containing struct column schema" $ \o ->
        Schema.Struct DenyDefault <$> withStructField "fields" o pSchemaStructFieldsV0
    "nested" ->
      pure . Aeson.withObject "object containing nested column schema" $ \o ->
        Schema.Nested <$> withStructField "table" o pTableSchemaV0
    "reversed" ->
      pure . Aeson.withObject "object containing reversed column schema" $ \o ->
        Schema.Reversed <$> withStructField "column" o pColumnSchemaV0
    _ ->
      Nothing
{-# INLINABLE pColumnSchemaV0 #-}

ppColumnSchemaV0 :: Schema.Column -> Aeson.Value
ppColumnSchemaV0 = \case
  Schema.Unit ->
    ppEnum $ Variant "unit" ppUnit
  Schema.Int _def _encoding ->
    ppEnum $ Variant "int" ppUnit
  Schema.Double _def ->
    ppEnum $ Variant "double" ppUnit
  Schema.Enum _def vs ->
    ppEnum . Variant "enum" $
      Aeson.object ["variants" .= Aeson.Array (Cons.toVector $ fmap ppSchemaVariantV0 vs)]
  Schema.Struct _def fs ->
    ppEnum . Variant "struct" $
      Aeson.object ["fields" .= Aeson.Array (Cons.toVector $ fmap ppSchemaFieldV0 fs)]
  Schema.Nested s ->
    ppEnum . Variant "nested" $
      Aeson.object ["table" .= ppTableSchemaV0 s]
  Schema.Reversed s ->
    ppEnum . Variant "reversed" $
      Aeson.object ["column" .= ppColumnSchemaV0 s]
{-# INLINABLE ppColumnSchemaV0 #-}

pSchemaEnumVariantsV0 :: Aeson.Value -> Aeson.Parser (Cons Boxed.Vector (Variant Schema.Column))
pSchemaEnumVariantsV0 =
  Aeson.withArray "non-empty array of enum variants" $ \xs -> do
    vs0 <- kmapM pSchemaVariantV0 xs
    case Boxed.uncons vs0 of
      Nothing ->
        fail "enums must have at least one variant"
      Just (v0, vs) ->
        pure $ Cons.from v0 vs
{-# INLINABLE pSchemaEnumVariantsV0 #-}

pSchemaVariantV0 :: Aeson.Value -> Aeson.Parser (Variant Schema.Column)
pSchemaVariantV0 =
  Aeson.withObject "object containing an enum variant" $ \o ->
    Variant
      <$> withStructField "name" o (fmap VariantName . pText)
      <*> withStructField "column" o pColumnSchemaV0
{-# INLINABLE pSchemaVariantV0 #-}

pSchemaStructFieldsV0 :: Aeson.Value -> Aeson.Parser (Cons Boxed.Vector (Field Schema.Column))
pSchemaStructFieldsV0 =
  Aeson.withArray "array of struct fields" $ \xs -> do
    fs0 <- kmapM pSchemaFieldV0 xs
    case Boxed.uncons fs0 of
      Nothing ->
        fail "structs must have at least one field"
      Just (f0, fs) ->
        pure $ Cons.from f0 fs
{-# INLINABLE pSchemaStructFieldsV0 #-}

pSchemaFieldV0 :: Aeson.Value -> Aeson.Parser (Field Schema.Column)
pSchemaFieldV0 =
  Aeson.withObject "object containing a struct field" $ \o ->
    Field
      <$> withStructField "name" o (fmap FieldName . pText)
      <*> withStructField "column" o pColumnSchemaV0
{-# INLINABLE pSchemaFieldV0 #-}

ppSchemaVariantV0 :: Variant Schema.Column -> Aeson.Value
ppSchemaVariantV0 (Variant (VariantName name) schema) =
  ppStruct [
      Field "name" $
        Aeson.String name
    , Field "column" $
        ppColumnSchemaV0 schema
    ]
{-# INLINABLE ppSchemaVariantV0 #-}

ppSchemaFieldV0 :: Field Schema.Column -> Aeson.Value
ppSchemaFieldV0 (Field (FieldName name) schema) =
  ppStruct [
      Field "name" $
        Aeson.String name
    , Field "column" $
        ppColumnSchemaV0 schema
    ]
{-# INLINABLE ppSchemaFieldV0 #-}

------------------------------------------------------------------------
-- v1

pTableSchemaV1 :: Aeson.Value -> Aeson.Parser Schema.Table
pTableSchemaV1 =
  pEnum pTableVariantV1
{-# INLINABLE pTableSchemaV1 #-}

pTableVariantV1 :: VariantName -> Maybe (Aeson.Value -> Aeson.Parser Schema.Table)
pTableVariantV1 = \case
  "binary" ->
    pure . Aeson.withObject "object containing binary schema" $ \o ->
      Schema.Binary
        <$> pDefaultFieldV1 o
        <*> pEncodingFieldV1 Encoding.Binary pBinaryEncodingV1 o
  "array" ->
    pure . Aeson.withObject "object containing array schema" $ \o ->
      Schema.Array
        <$> pDefaultFieldV1 o
        <*> withStructField "element" o pColumnSchemaV1
  "map" ->
    pure . Aeson.withObject "object containing map schema" $ \o ->
      Schema.Map
        <$> pDefaultFieldV1 o
        <*> withStructField "key" o pColumnSchemaV1
        <*> withStructField "value" o pColumnSchemaV1
  _ ->
    Nothing
{-# INLINABLE pTableVariantV1 #-}

ppTableSchemaV1 :: Schema.Table -> Aeson.Value
ppTableSchemaV1 = \case
  Schema.Binary def encoding ->
    ppEnum . Variant "binary" . Aeson.object $
      ppDefaultFieldV1 def <>
      ppEncodingFieldV1 Encoding.Binary ppBinaryEncodingV1 encoding
  Schema.Array def e ->
    ppEnum . Variant "array" . Aeson.object $
      ppDefaultFieldV1 def <> [
        "element" .= ppColumnSchemaV1 e
      ]
  Schema.Map def k v ->
    ppEnum . Variant "map" . Aeson.object $
      ppDefaultFieldV1 def <> [
        "key" .= ppColumnSchemaV1 k
      , "value" .= ppColumnSchemaV1 v
      ]
{-# INLINABLE ppTableSchemaV1 #-}

pDefaultFieldV1 :: Aeson.Object -> Aeson.Parser Default
pDefaultFieldV1 o =
  fromMaybe DenyDefault
    <$> withOptionalField "default" o pDefaultV1
{-# INLINABLE pDefaultFieldV1 #-}

ppDefaultFieldV1 :: Default -> [Aeson.Pair]
ppDefaultFieldV1 = \case
  DenyDefault ->
    []
  AllowDefault ->
    [ "default" .= ppDefaultV1 AllowDefault ]
{-# INLINABLE ppDefaultFieldV1 #-}

pDefaultV1 :: Aeson.Value -> Aeson.Parser Default
pDefaultV1 =
  pEnum $ \case
    "deny" ->
      pure . const $ pure DenyDefault
    "allow" ->
      pure . const $ pure AllowDefault
    _ ->
      Nothing
{-# INLINABLE pDefaultV1 #-}

ppDefaultV1 :: Default -> Aeson.Value
ppDefaultV1 = \case
  DenyDefault ->
    ppEnum $ Variant "deny" ppUnit
  AllowDefault ->
    ppEnum $ Variant "allow" ppUnit
{-# INLINABLE ppDefaultV1 #-}

pEncodingFieldV1 :: a -> (Aeson.Value -> Aeson.Parser a) -> Aeson.Object -> Aeson.Parser a
pEncodingFieldV1 def p o =
  fromMaybe def
    <$> withOptionalField "encoding" o p
{-# INLINABLE pEncodingFieldV1 #-}

ppEncodingFieldV1 :: Eq a => a -> (a -> Aeson.Value) -> a -> [Aeson.Pair]
ppEncodingFieldV1 def pp x =
  if def == x then
    []
  else
    [ "encoding" .= pp x ]
{-# INLINABLE ppEncodingFieldV1 #-}

pBinaryEncodingV1 :: Aeson.Value -> Aeson.Parser Encoding.Binary
pBinaryEncodingV1 =
  pEnum $ \case
    "binary" ->
      pure . const $ pure Encoding.Binary
    "utf8" ->
      pure . const $ pure Encoding.Utf8
    _ ->
      Nothing
{-# INLINABLE pBinaryEncodingV1 #-}

ppBinaryEncodingV1 :: Encoding.Binary -> Aeson.Value
ppBinaryEncodingV1 = \case
  Encoding.Binary ->
    ppEnum $ Variant "binary" ppUnit
  Encoding.Utf8 ->
    ppEnum $ Variant "utf8" ppUnit
{-# INLINABLE ppBinaryEncodingV1 #-}

pColumnSchemaV1 :: Aeson.Value -> Aeson.Parser Schema.Column
pColumnSchemaV1 =
  pEnum $ \case
    "unit" ->
      pure . const $ pure Schema.Unit
    "int" ->
      pure . Aeson.withObject "object containing int column schema" $ \o ->
        Schema.Int
          <$> pDefaultFieldV1 o
          <*> pEncodingFieldV1 Encoding.Int pIntEncodingV1 o
    "double" ->
      pure . Aeson.withObject "object containing double column schema" $ \o ->
        Schema.Double
          <$> pDefaultFieldV1 o
    "enum" ->
      pure . Aeson.withObject "object containing enum column schema" $ \o ->
        Schema.Enum
          <$> pDefaultFieldV1 o
          <*> withStructField "variants" o pSchemaEnumVariantsV1
    "struct" ->
      pure . Aeson.withObject "object containing struct column schema" $ \o ->
        Schema.Struct
          <$> pDefaultFieldV1 o
          <*> withStructField "fields" o pSchemaStructFieldsV1
    "reversed" ->
      pure $
        fmap Schema.Reversed . pColumnSchemaV1
    nested ->
      fmap2 Schema.Nested <$> pTableVariantV1 nested
{-# INLINABLE pColumnSchemaV1 #-}

ppColumnSchemaV1 :: Schema.Column -> Aeson.Value
ppColumnSchemaV1 = \case
  Schema.Unit ->
    ppEnum $ Variant "unit" ppUnit
  Schema.Int def encoding ->
    ppEnum . Variant "int" . Aeson.object $
      ppDefaultFieldV1 def <>
      ppEncodingFieldV1 Encoding.Int ppIntEncodingV1 encoding
  Schema.Double def ->
    ppEnum . Variant "double" . Aeson.object $
      ppDefaultFieldV1 def
  Schema.Enum def vs ->
    ppEnum . Variant "enum" . Aeson.object $
      ppDefaultFieldV1 def <> [
        "variants" .= Aeson.Array (Cons.toVector $ fmap ppSchemaVariantV1 vs)
      ]
  Schema.Struct def fs ->
    ppEnum . Variant "struct" . Aeson.object $
      ppDefaultFieldV1 def <> [
        "fields" .= Aeson.Array (Cons.toVector $ fmap ppSchemaFieldV1 fs)
      ]
  Schema.Nested s ->
    ppTableSchemaV1 s
  Schema.Reversed s ->
    ppEnum . Variant "reversed" $
      ppColumnSchemaV1 s
{-# INLINABLE ppColumnSchemaV1 #-}

pIntEncodingV1 :: Aeson.Value -> Aeson.Parser Encoding.Int
pIntEncodingV1 =
  pEnum $ \case
    "int" ->
      pure . const $ pure Encoding.Int
    "date" ->
      pure . const $ pure Encoding.Date
    "time" ->
      pure . Aeson.withObject "object containing a time encoding" $ \o ->
        withStructField "interval" o pIntTimeEncodingV1
    _ ->
      Nothing
{-# INLINABLE pIntEncodingV1 #-}

pIntTimeEncodingV1 :: Aeson.Value -> Aeson.Parser Encoding.Int
pIntTimeEncodingV1 =
  pEnum $ \case
    "seconds" ->
      pure . const $ pure Encoding.TimeSeconds
    "milliseconds" ->
      pure . const $ pure Encoding.TimeMilliseconds
    "microseconds" ->
      pure . const $ pure Encoding.TimeMicroseconds
    _ ->
      Nothing
{-# INLINABLE pIntTimeEncodingV1 #-}

ppIntEncodingV1 :: Encoding.Int -> Aeson.Value
ppIntEncodingV1 = \case
  Encoding.Int ->
    ppEnum $ Variant "int" ppUnit

  Encoding.Date ->
    ppEnum $ Variant "date" ppUnit

  Encoding.TimeSeconds ->
    ppEnum . Variant "time" $
      ppStruct [
          Field "interval" $
            ppEnum $ Variant "seconds" ppUnit
        ]

  Encoding.TimeMilliseconds ->
    ppEnum . Variant "time" $
      ppStruct [
          Field "interval" $
            ppEnum $ Variant "milliseconds" ppUnit
        ]

  Encoding.TimeMicroseconds ->
    ppEnum . Variant "time" $
      ppStruct [
          Field "interval" $
            ppEnum $ Variant "microseconds" ppUnit
        ]
{-# INLINABLE ppIntEncodingV1 #-}

pSchemaEnumVariantsV1 :: Aeson.Value -> Aeson.Parser (Cons Boxed.Vector (Variant Schema.Column))
pSchemaEnumVariantsV1 =
  Aeson.withArray "non-empty array of enum variants" $ \xs -> do
    vs0 <- kmapM pSchemaVariantV1 xs
    case Boxed.uncons vs0 of
      Nothing ->
        fail "enums must have at least one variant"
      Just (v0, vs) ->
        pure $ Cons.from v0 vs
{-# INLINABLE pSchemaEnumVariantsV1 #-}

pSchemaVariantV1 :: Aeson.Value -> Aeson.Parser (Variant Schema.Column)
pSchemaVariantV1 =
  Aeson.withObject "object containing an enum variant" $ \o ->
    Variant
      <$> withStructField "name" o (fmap VariantName . pText)
      <*> withStructField "schema" o pColumnSchemaV1
{-# INLINABLE pSchemaVariantV1 #-}

pSchemaStructFieldsV1 :: Aeson.Value -> Aeson.Parser (Cons Boxed.Vector (Field Schema.Column))
pSchemaStructFieldsV1 =
  Aeson.withArray "array of struct fields" $ \xs -> do
    fs0 <- kmapM pSchemaFieldV1 xs
    case Boxed.uncons fs0 of
      Nothing ->
        fail "structs must have at least one field"
      Just (f0, fs) ->
        pure $ Cons.from f0 fs
{-# INLINABLE pSchemaStructFieldsV1 #-}

pSchemaFieldV1 :: Aeson.Value -> Aeson.Parser (Field Schema.Column)
pSchemaFieldV1 =
  Aeson.withObject "object containing a struct field" $ \o ->
    Field
      <$> withStructField "name" o (fmap FieldName . pText)
      <*> withStructField "schema" o pColumnSchemaV1
{-# INLINABLE pSchemaFieldV1 #-}

ppSchemaVariantV1 :: Variant Schema.Column -> Aeson.Value
ppSchemaVariantV1 (Variant (VariantName name) schema) =
  ppStruct [
      Field "name" $
        Aeson.String name
    , Field "schema" $
        ppColumnSchemaV1 schema
    ]
{-# INLINABLE ppSchemaVariantV1 #-}

ppSchemaFieldV1 :: Field Schema.Column -> Aeson.Value
ppSchemaFieldV1 (Field (FieldName name) schema) =
  ppStruct [
      Field "name" $
        Aeson.String name
    , Field "schema" $
        ppColumnSchemaV1 schema
    ]
{-# INLINABLE ppSchemaFieldV1 #-}
