{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module Llvm.MetaData where

import Llvm.Types
import FastString
import Outputable

-- The LLVM Metadata System.
--
-- The LLVM metadata feature is poorly documented but roughly follows the
-- following design:
-- * Metadata can be constructed in a few different ways (See below).
-- * After which it can either be attached to LLVM statements to pass along
-- extra information to the optimizer and code generator OR specifically named
-- metadata has an affect on the whole module (i.e., linking behaviour).
--
--
-- # Constructing metadata
-- Metadata comes largely in three forms:
--
-- * Metadata expressions -- these are the raw metadata values that encode
--   information. They consist of metadata strings, metadata nodes, regular
--   LLVM values (both literals and references to global variables) and
--   metadata expressions (i.e., recursive data type). Some examples:
--     !{ !"hello", !0, i32 0 }
--     !{ !1, !{ i32 0 } }
--
-- * Metadata nodes -- global metadata variables that attach a metadata
--   expression to a number. For example:
--     !0 = !{ [<metadata expressions>] !}
--
-- * Named metadata -- global metadata variables that attach a metadata nodes
--   to a name. Used ONLY to communicated module level information to LLVM
--   through a meaningful name. For example:
--     !llvm.module.linkage = !{ !0, !1 }
--
--
-- # Using Metadata
-- Using metadata depends on the form it is in:
--
-- * Attach to instructions -- metadata can be attached to LLVM instructions
--   using a specific reference as follows:
--     %l = load i32* @glob, !nontemporal !10
--     %m = load i32* @glob, !nontemporal !{ i32 0, !{ i32 0 } }
--   Only metadata nodes or expressions can be attached, named metadata cannot.
--   Refer to LLVM documentation for which instructions take metadata and its
--   meaning.
--
-- * As arguments -- llvm functions can take metadata as arguments, for
--   example:
--     call void @llvm.dbg.value(metadata !{ i32 0 }, i64 0, metadata !1)
--   As with instructions, only metadata nodes or expressions can be attached.
--
-- * As a named metadata -- Here the metadata is simply declared in global
--   scope using a specific name to communicate module level information to LLVM.
--   For example:
--     !llvm.module.linkage = !{ !0, !1 }
--

-- | A reference to an un-named metadata node.
newtype MetaId = MetaId Int
               deriving (Eq, Ord, Enum)

instance Outputable MetaId where
    ppr (MetaId n) = char '!' <> int n

data EmissionKind = NoDebug | FullDebug | LineTablesOnly deriving (Eq, Ord)

instance Outputable EmissionKind where
  ppr NoDebug = text "NoDebug"
  ppr FullDebug = text "FullDebug"
  ppr LineTablesOnly = text "LineTablesOnly"

-- | LLVM metadata expressions
data MetaExpr = MetaStr !LMString
              | MetaNode !MetaId
              | MetaVar !LlvmVar
              | MetaStruct [MetaExpr]
              | MetaDIFile { difFilename  :: !FastString
                           , difDirectory :: !FastString
                           }
              | MetaDISubroutineType { distType     :: ![MetaExpr] }
              | MetaDICompileUnit { dicuLanguage     :: !FastString
                                  , dicuFile         :: !MetaId
                                  , dicuProducer     :: !FastString
                                  , dicuIsOptimized  :: !Bool
                                  , dicuEmissionKind :: !EmissionKind
                                  }
              | MetaDISubprogram { disName          :: !FastString
                                 , disLinkageName   :: !FastString
                                 , disScope         :: !MetaId
                                 , disFile          :: !MetaId
                                 , disLine          :: !Int
                                 , disType          :: !MetaId
                                 , disIsDefinition  :: !Bool
                                 , disUnit          :: !MetaId
                                 }
              | MetaDILocation { dilLine   :: !Int
                               , dilColumn :: !Int
                               , dilScope  :: !MetaId
                               -- TODO LLVM supports inlinedAt. Is this useful for GHC?
                               }
              deriving (Eq)

instance Outputable MetaExpr where
  ppr (MetaVar (LMLitVar (LMNullLit _))) = text "null"
  ppr (MetaStr    s ) = char '!' <> doubleQuotes (ftext s)
  ppr (MetaNode   n ) = ppr n
  ppr (MetaVar    v ) = ppr v
  ppr (MetaStruct es) = char '!' <> braces (ppCommaJoin es)
  ppr (MetaDIFile {..}) =
      specialMetadata False "DIFile"
      [ (text "filename" , doubleQuotes $ ftext difFilename)
      , (text "directory", doubleQuotes $ ftext difDirectory)
      ]
  ppr (MetaDISubroutineType {..}) =
      specialMetadata False "DISubroutineType"
      [ (text "types", ppr $ MetaStruct distType ) ]
  ppr (MetaDICompileUnit {..}) =
      specialMetadata True "DICompileUnit"
      [ (text "language"   , ftext dicuLanguage)
      , (text "file"       , ppr dicuFile)
      , (text "producer"   , doubleQuotes $ ftext dicuProducer)
      , (text "isOptimized", if dicuIsOptimized
                            then text "true"
                            else text "false")
      , (text "emissionKind", ppr dicuEmissionKind)
      ]
  ppr (MetaDISubprogram {..}) =
      specialMetadata disIsDefinition "DISubprogram"
      [ ("name"        , doubleQuotes $ ftext disName)
      , ("linkageName" , doubleQuotes $ ftext disLinkageName)
      , ("scope"       , ppr disScope)
      , ("file"        , ppr disFile)
      , ("line"        , ppr disLine)
      , ("type"        , ppr disType)
      , ("isDefinition", if disIsDefinition
                              then text "true"
                              else text "false")
      , ("unit"        , ppr disUnit)
      ]
  ppr (MetaDILocation {..}) =
      specialMetadata False "DILocation"
      [ ("line", ppr dilLine)
      , ("column", ppr dilColumn)
      , ("scope", ppr dilScope)
      ]


specialMetadata :: Bool -> SDoc -> [(SDoc, SDoc)] -> SDoc
specialMetadata distinct nodeName fields =
    (if distinct
      then text "distinct "
      else text "")
    <> char '!' <> nodeName
    <> parens (hsep $ punctuate comma $ map (\(k,v) -> k <> colon <+> v) fields)

-- | Associates some metadata with a specific label for attaching to an
-- instruction.
data MetaAnnot = MetaAnnot LMString MetaExpr
               deriving (Eq)

-- | Metadata declarations. Metadata can only be declared in global scope.
data MetaDecl
    -- | Named metadata. Only used for communicating module information to
    -- LLVM. ('!name = !{ [!<n>] }' form).
    = MetaNamed !LMString [MetaId]
    -- | Metadata node declaration.
    -- ('!0 = metadata !{ <metadata expression> }' form).
    | MetaUnnamed !MetaId !MetaExpr
