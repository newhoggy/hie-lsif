{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeInType                 #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE GADTs                      #-}

module LSIF where

import           Control.Applicative
import qualified Data.Aeson                                 as A
import           Data.Text                                  (Text)
import qualified Data.Text                                  as T
import qualified Language.Haskell.LSP.Types                 as LSP
import Data.Kind
import qualified Data.Void as Void
import Data.Char
import GHC.Generics hiding (MetaData)
import Data.List
import Unsafe.Coerce
import Data.Proxy

{-
Hacks to get avoid boilerplate when constructing elements.
-}

type Constr a = Args (Rep a) a -- ^ Type of the constructor for A without `Empty`s

type family Args a r where
  Args (M1 k m c1) r = Args c1 r
  Args (a :*: b) r = Args a (Args b r)
  Args (K1 m Empty) r = r
  Args (K1 m a) r = a -> r
  Args U1 r = r

class MkConstr f where
  mkConstr' :: forall r a. (f a -> r) -> Args f r

instance MkConstr c1 => MkConstr (M1 k m c1) where
  mkConstr' k = mkConstr' (k . M1)

instance (MkConstr a, MkConstr b) => MkConstr (a :*: b) where
  mkConstr' k = mkConstr' (\x -> mkConstr' (k . (\y -> x :*: y)))

instance {-# OVERLAPPABLE #-} MkConstr (K1 m a) where
  mkConstr' k = unsafeCoerce $ k . K1

instance MkConstr (K1 m Empty) where
  mkConstr' k = k (K1 Nothing)

instance MkConstr U1 where
  mkConstr' k = k U1

mkConstr :: forall r. (MkConstr (Rep r), Generic r) => Proxy r -> Constr r
mkConstr _ = mkConstr' (to :: Rep r x -> r)

{-
Actual definitions
-}

aesonOpts :: A.Options
aesonOpts
  = A.defaultOptions
  { A.allNullaryToStringTag = True
  , A.constructorTagModifier = \xs -> map toLower (take 1 xs) ++ drop 1 xs
  , A.omitNothingFields = True
  , A.fieldLabelModifier = drop 1
  }

type Empty = Maybe Void.Void -- Use this instead of () as Aeson can omit Nothing fields

data (:|:) a b = InL a | InR b deriving (Eq, Show, Ord)

instance (A.ToJSON a, A.ToJSON b) => A.ToJSON (a :|: b) where
  toJSON (InL a) = A.toJSON a
  toJSON (InR b) = A.toJSON b

-- | An Id to identify a vertex or an edge.
type LsifId = Int :|: Text

type WhenV t l a = MatchV t '[ '(l,a) ]
type WhenVs t xs a = MatchV t (Assoc xs a)

type family Assoc (xs :: [a]) (y :: b) :: [(a,b)] where
  Assoc '[] y = '[]
  Assoc (x ': xs) y = '(x,y) ': (Assoc xs y)

type family MatchV (l :: ElementType) (xs :: [(VertexLabel, Type)]) where
  MatchV (Vertex l) ('(l,t) ': xs) = t
  MatchV (Vertex l) ('(k,t) ': xs) = MatchV (Vertex l) xs
  MatchV a b = Empty

type family WhenE (t :: ElementType) (a :: Type) where
  WhenE (Edge l) a = a
  WhenE t        a = Empty

type family WhenE1 (t :: ElementType) (l :: EdgeLabel) (a :: Type) where
  WhenE1 (Edge l) l a = a
  WhenE1 t        l a = Empty

type family Label (t :: ElementType) :: Type where
  Label (Vertex l) = SVertexLabel l
  Label (Edge l) = SEdgeLabel l

type family Tag (t :: ElementType) :: Type where
  Tag (Vertex ('Range Untagged)) = Empty
  Tag (Vertex ('Range rt)) = RangeTag rt
  Tag a                    = Empty

type family WhenRange (t :: ElementType) (a :: Type) :: Type where
  WhenRange (Vertex ('Range rt)) a = a
  WhenRange t          a = Empty

data SomeElement where
  SomeElement :: forall t. Element t -> SomeElement

-- | An element in the graph
data Element (t :: ElementType)
  = Element
  { _id    :: LsifId
  , _type  :: SElementType t

  , _label :: Label t

  , _tag   :: Tag t

  , _outV :: WhenE t LsifId
  , _inV  :: WhenE t LsifId

  , _property :: WhenE1 t 'Item ItemEdgeProperties

  , _start :: WhenRange t LSP.Position
  , _end   :: WhenRange t LSP.Position

  , _range :: WhenV t 'Location LSP.Range

  , _version :: MatchV t '[ '( 'MetaData, Text ), '( 'PackageInformation, Maybe Text) ]
  , _projectRoot :: WhenV t 'MetaData (Maybe LSP.Uri)
  , _toolInfo :: WhenV t 'MetaData (Maybe ToolInfo)

  , _kind     :: MatchV t '[ '( 'Project,Text), '( 'Moniker,MonikerKind)]
  , _resource :: WhenV t 'Project (Maybe LSP.Uri)

  , _uri        :: MatchV t '[ '( 'Document, LSP.Uri), '( 'PackageInformation, Maybe LSP.Uri)]
  , _languageId :: WhenV t 'Document Text

  , _data     :: WhenVs t ['Project,'Document] (Maybe AdditionalData)
  , _contents :: WhenVs t ['Project,'Document,'PackageInformation] (Maybe Text)

  , _scheme :: WhenV t 'Moniker Text
  , _identifier :: WhenV t 'Moniker Text

  , _name :: WhenV t 'PackageInformation Text
  , _manager :: WhenV t 'PackageInformation Text
  , _repository :: WhenV t 'PackageInformation (Maybe Repository)

  , _declarations :: WhenV t 'ReferenceResult (Maybe [RangeId :|: LSP.Location])
  , _definitions  :: WhenV t 'ReferenceResult (Maybe [RangeId :|: LSP.Location])
  , _references   :: WhenV t 'ReferenceResult (Maybe [RangeId :|: LSP.Location])
  , _referenceResults :: WhenV t 'ReferenceResult (Maybe [LsifId])

  , _implementationResults :: WhenV t 'ImplementationResult (Maybe [LsifId])

  , _result :: Result t
  } deriving Generic

type family Result (t :: ElementType) :: Type where
  Result (Vertex 'DocumentSymbolResult) = [LSP.DocumentSymbol] :|: [RangeBasedDocumentSymbol]
  Result (Vertex 'DiagnosticResult    ) = [LSP.Diagnostic]
  Result (Vertex 'FoldingRangeResult  ) = [LSP.FoldingRange]
  Result (Vertex 'DocumentLinkResult  ) = [LSP.DocumentLink]
  Result (Vertex 'DeclarationResult   ) = Maybe [RangeId :|: LSP.Location]
  Result (Vertex 'DefinitionResult    ) = Maybe [RangeId :|: LSP.Location]
  Result (Vertex 'TypeDefinitionResult) = Maybe [RangeId :|: LSP.Location]
  Result (Vertex 'HoverResult         ) = LSP.Hover
  Result (Vertex 'ImplementationResult) = Maybe [RangeId :|: LSP.Location]
  Result t                              = Empty

type V a = Element (Vertex a)

type Range a = V ('Range a)

type DefinitionRange = Range 'Definition
type DeclarationRange = Range 'Declaration
type ReferenceRange = Range 'Reference
type UnknownRange = Range 'Unknown
type UntaggedRange = Range 'Untagged

type ResultSet            = V 'ResultSet
type Location             = V 'Location
type MetaData             = V 'MetaData
type Project              = V 'Project
type Document             = V 'Document
type Moniker              = V 'Moniker
type PackageInformation   = V 'PackageInformation
type DocumentSymbolResult = V 'DocumentSymbolResult
type FoldingRangeResult   = V 'FoldingRangeResult
type DocumentLinkResult   = V 'DocumentLinkResult
type DiagnosticResult     = V 'DiagnosticResult
type DeclarationResult    = V 'DeclarationResult
type DefinitionResult     = V 'DefinitionResult
type TypeDefinitionResult = V 'TypeDefinitionResult
type HoverResult          = V 'HoverResult
type ReferenceResult      = V 'ReferenceResult
type ImplementationResult = V 'ImplementationResult

mkDefinitionRange      lid = mkConstr (Proxy @DefinitionRange) lid SVertex SRange
mkDeclarationRange     lid = mkConstr (Proxy @DeclarationRange) lid SVertex SRange
mkReferenceRange       lid = mkConstr (Proxy @ReferenceRange) lid SVertex SRange
mkUnknownRange         lid = mkConstr (Proxy @UnknownRange) lid SVertex SRange
mkUntaggedRange        lid = mkConstr (Proxy @UntaggedRange) lid SVertex SRange

mkResultSet            lid = mkConstr (Proxy @ResultSet) lid SVertex SResultSet
mkLocation             lid = mkConstr (Proxy @Location) lid SVertex SLocation
mkMetaData             lid = mkConstr (Proxy @MetaData) lid SVertex SMetaData
mkProject              lid = mkConstr (Proxy @Project) lid SVertex SProject
mkDocument             lid = mkConstr (Proxy @Document) lid SVertex SDocument
mkMoniker              lid = mkConstr (Proxy @Moniker) lid SVertex SMoniker
mkPackageInformation   lid = mkConstr (Proxy @PackageInformation) lid SVertex SPackageInformation
mkDocumentSymbolResult lid = mkConstr (Proxy @DocumentSymbolResult) lid SVertex SDocumentSymbolResult
mkFoldingRangeResult   lid = mkConstr (Proxy @FoldingRangeResult) lid SVertex SFoldingRangeResult
mkDocumentLinkResult   lid = mkConstr (Proxy @DocumentLinkResult) lid SVertex SDocumentLinkResult
mkDiagnosticResult     lid = mkConstr (Proxy @DiagnosticResult) lid SVertex SDiagnosticResult
mkDeclarationResult    lid = mkConstr (Proxy @DeclarationResult) lid SVertex SDeclarationResult
mkDefinitionResult     lid = mkConstr (Proxy @DefinitionResult) lid SVertex SDefinitionResult
mkTypeDefinitionResult lid = mkConstr (Proxy @TypeDefinitionResult) lid SVertex STypeDefinitionResult
mkHoverResult          lid = mkConstr (Proxy @HoverResult) lid SVertex SHoverResult
mkReferenceResult      lid = mkConstr (Proxy @ReferenceResult) lid SVertex SReferenceResult
mkImplementationResult lid = mkConstr (Proxy @ImplementationResult) lid SVertex SImplementationResult

instance A.ToJSON DefinitionRange where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DeclarationRange where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ReferenceRange where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON UnknownRange where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON UntaggedRange where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ResultSet where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON Location where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON MetaData where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON Project where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON Document where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON Moniker where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON PackageInformation where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DocumentSymbolResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON FoldingRangeResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DocumentLinkResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DiagnosticResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DeclarationResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DefinitionResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON TypeDefinitionResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON HoverResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ReferenceResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ImplementationResult where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

data ElementType = Vertex VertexLabel | Edge EdgeLabel
data SElementType t where
  SVertex :: SElementType (Vertex vl)
  SEdge   :: SElementType (Edge el)

instance A.ToJSON (SElementType a) where
  toJSON SVertex = A.toJSON "vertex"
  toJSON SEdge = A.toJSON "edge"

type RangeId = LsifId

-- | All known vertices label types
data VertexLabel
  = MetaData
  | Project
  | Range RangeTagType
  | Location
  | Document
  | Moniker
  | PackageInformation
  | ResultSet
  | DocumentSymbolResult
  | FoldingRangeResult
  | DocumentLinkResult
  | DiagnosticResult
  | DeclarationResult
  | DefinitionResult
  | TypeDefinitionResult
  | HoverResult
  | ReferenceResult
  | ImplementationResult

data SVertexLabel (v :: VertexLabel) where
  SMetaData             :: SVertexLabel 'MetaData
  SProject              :: SVertexLabel 'Project
  SRange                :: forall a. SVertexLabel ('Range a)
  SLocation             :: SVertexLabel 'Location
  SDocument             :: SVertexLabel 'Document
  SMoniker              :: SVertexLabel 'Moniker
  SPackageInformation   :: SVertexLabel 'PackageInformation
  SResultSet            :: SVertexLabel 'ResultSet
  SDocumentSymbolResult :: SVertexLabel 'DocumentSymbolResult
  SFoldingRangeResult   :: SVertexLabel 'FoldingRangeResult
  SDocumentLinkResult   :: SVertexLabel 'DocumentLinkResult
  SDiagnosticResult     :: SVertexLabel 'DiagnosticResult
  SDeclarationResult    :: SVertexLabel 'DeclarationResult
  SDefinitionResult     :: SVertexLabel 'DefinitionResult
  STypeDefinitionResult :: SVertexLabel 'TypeDefinitionResult
  SHoverResult          :: SVertexLabel 'HoverResult
  SReferenceResult      :: SVertexLabel 'ReferenceResult
  SImplementationResult :: SVertexLabel 'ImplementationResult

instance A.ToJSON (SVertexLabel a) where
  toJSON SMetaData             = A.toJSON "metaData"
  toJSON SProject              = A.toJSON "project"
  toJSON SRange                = A.toJSON "range"
  toJSON SLocation             = A.toJSON "location"
  toJSON SDocument             = A.toJSON "document"
  toJSON SMoniker              = A.toJSON "moniker"
  toJSON SPackageInformation   = A.toJSON "packageInformation"
  toJSON SResultSet            = A.toJSON "resultSet"
  toJSON SDocumentSymbolResult = A.toJSON "documentSymbolResult"
  toJSON SFoldingRangeResult   = A.toJSON "foldingRangeResult"
  toJSON SDocumentLinkResult   = A.toJSON "documentLinkResult"
  toJSON SDiagnosticResult     = A.toJSON "diagnosticResult"
  toJSON SDeclarationResult    = A.toJSON "declarationResult"
  toJSON SDefinitionResult     = A.toJSON "definitionResult"
  toJSON STypeDefinitionResult = A.toJSON "typeDefinitionResult"
  toJSON SHoverResult          = A.toJSON "hoverResult"
  toJSON SReferenceResult      = A.toJSON "referenceResult"
  toJSON SImplementationResult = A.toJSON "implementationResult"

data MonikerKind = Import | Export deriving Generic

instance A.ToJSON MonikerKind where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

data RangeTagType
  = Declaration
  | Definition
  | Reference
  | Unknown
  | Untagged
  deriving Generic

instance A.ToJSON RangeTagType where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

data SRangeTagType (rt :: RangeTagType) where
  SDeclaration :: SRangeTagType Declaration
  SDefinition  :: SRangeTagType Definition
  SReference   :: SRangeTagType Reference
  SUnknown     :: SRangeTagType Unknown

instance A.ToJSON (SRangeTagType rt) where
  toJSON SDeclaration = A.toJSON Declaration
  toJSON SDefinition  = A.toJSON Definition
  toJSON SReference   = A.toJSON Reference
  toJSON SUnknown     = A.toJSON Unknown

data EdgeLabel
  = Contains
  | Item
  | RefersTo
  | EMoniker
  | EPackageInformation
  | TextDocument_DocumentSymbol
  | TextDocument_FoldingRange
  | TextDocument_DocumentLink
  | TextDocument_Diagnostic
  | TextDocument_Definition
  | TextDocument_Declaration
  | TextDocument_TypeDefinition
  | TextDocument_Hover
  | TextDocument_References
  | TextDocument_Implementation
  deriving (Eq,Ord,Generic,Enum,Show)

type E l = Element (Edge l)

type ContainsEdge = E 'Contains
type ItemEdge = E 'Item
type RefersToEdge = E 'RefersTo
type MonikerEdge = E 'EMoniker
type PackageInformationEdge = E 'EPackageInformation
type DocumentSymbolEdge = E 'TextDocument_DocumentSymbol
type FoldingRangeEdge = E 'TextDocument_FoldingRange
type DocumentLinkEdge = E 'TextDocument_DocumentLink
type DiagnosticEdge = E 'TextDocument_Diagnostic
type DefinitionEdge = E 'TextDocument_Definition
type DeclarationEdge = E 'TextDocument_Declaration
type TypeDefinitionEdge = E 'TextDocument_TypeDefinition
type HoverEdge = E 'TextDocument_Hover
type ReferencesEdge = E 'TextDocument_References
type ImplementationEdge = E 'TextDocument_Implementation

instance A.ToJSON ContainsEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ItemEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON RefersToEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON MonikerEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON PackageInformationEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DocumentSymbolEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON FoldingRangeEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DocumentLinkEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DiagnosticEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DefinitionEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DeclarationEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON TypeDefinitionEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON HoverEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ReferencesEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ImplementationEdge where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

mkContainsEdge lid
  = mkConstr (Proxy @(Element (Edge 'Contains))) lid SEdge SContains
mkItemEdge lid
  = mkConstr (Proxy @(Element (Edge 'Item))) lid SEdge SItem
mkRefersToEdge lid
  = mkConstr (Proxy @(Element (Edge 'RefersTo))) lid SEdge SRefersTo
mkMonikerEdge lid
  = mkConstr (Proxy @(Element (Edge 'EMoniker))) lid SEdge SEMoniker
mkPackageInformationEdge lid
  = mkConstr (Proxy @(Element (Edge 'EPackageInformation))) lid SEdge SEPackageInformation
mkDocumentSymbolEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_DocumentSymbol))) lid SEdge STextDocument_DocumentSymbol
mkFoldingRangeEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_FoldingRange))) lid SEdge STextDocument_FoldingRange
mkDocumentLinkEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_DocumentLink))) lid SEdge STextDocument_DocumentLink
mkDiagnosticEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_Diagnostic))) lid SEdge STextDocument_Diagnostic
mkDefinitionEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_Definition))) lid SEdge STextDocument_Definition
mkDeclarationEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_Declaration))) lid SEdge STextDocument_Declaration
mkTypeDefinitionEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_TypeDefinition))) lid SEdge STextDocument_TypeDefinition
mkHoverEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_Hover))) lid SEdge STextDocument_Hover
mkReferencesEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_References))) lid SEdge STextDocument_References
mkImplementationEdge lid
  = mkConstr (Proxy @(Element (Edge 'TextDocument_Implementation))) lid SEdge STextDocument_Implementation

edgeOptions :: A.Options
edgeOptions = aesonOpts { A.constructorTagModifier =
  \xs -> intercalate "/"
       $ map (A.constructorTagModifier aesonOpts)
       $ words
       $ map (\c -> if c == '_' then ' ' else c)
       $ maybe xs id (stripPrefix "E" xs)
  }

instance A.ToJSON EdgeLabel where
  toEncoding = A.genericToEncoding edgeOptions
  toJSON = A.genericToJSON edgeOptions

data SEdgeLabel (el :: EdgeLabel) where
  SContains :: SEdgeLabel Contains
  SItem :: SEdgeLabel Item
  SRefersTo :: SEdgeLabel RefersTo
  SEMoniker :: SEdgeLabel EMoniker
  SEPackageInformation :: SEdgeLabel EPackageInformation
  STextDocument_DocumentSymbol :: SEdgeLabel TextDocument_DocumentSymbol
  STextDocument_FoldingRange :: SEdgeLabel TextDocument_FoldingRange
  STextDocument_DocumentLink :: SEdgeLabel TextDocument_DocumentLink
  STextDocument_Diagnostic :: SEdgeLabel TextDocument_Diagnostic
  STextDocument_Definition :: SEdgeLabel TextDocument_Definition
  STextDocument_Declaration :: SEdgeLabel TextDocument_Declaration
  STextDocument_TypeDefinition :: SEdgeLabel TextDocument_TypeDefinition
  STextDocument_Hover :: SEdgeLabel TextDocument_Hover
  STextDocument_References :: SEdgeLabel TextDocument_References
  STextDocument_Implementation :: SEdgeLabel TextDocument_Implementation

instance A.ToJSON (SEdgeLabel (el :: EdgeLabel)) where
  toJSON SContains = A.toJSON Contains
  toJSON SItem = A.toJSON Item
  toJSON SRefersTo = A.toJSON RefersTo
  toJSON SEMoniker = A.toJSON EMoniker
  toJSON SEPackageInformation = A.toJSON EPackageInformation
  toJSON STextDocument_DocumentSymbol = A.toJSON TextDocument_DocumentSymbol
  toJSON STextDocument_FoldingRange = A.toJSON TextDocument_FoldingRange
  toJSON STextDocument_DocumentLink = A.toJSON TextDocument_DocumentLink
  toJSON STextDocument_Diagnostic = A.toJSON TextDocument_Diagnostic
  toJSON STextDocument_Definition = A.toJSON TextDocument_Definition
  toJSON STextDocument_Declaration = A.toJSON TextDocument_Declaration
  toJSON STextDocument_TypeDefinition = A.toJSON TextDocument_TypeDefinition
  toJSON STextDocument_Hover = A.toJSON TextDocument_Hover
  toJSON STextDocument_References = A.toJSON TextDocument_References
  toJSON STextDocument_Implementation = A.toJSON TextDocument_Implementation

type family When2 (a :: k) (b :: k) (c :: k) (t :: Type) :: Type where
  When2 a a b t = t
  When2 a b a t = t
  When2 a b c t = Empty

data RangeTag (t :: RangeTagType)
  = RangeTag
  { _type        :: SRangeTagType t
  , _text        :: Text
  , _kind        :: When2 t Declaration Definition LSP.SymbolKind
  , _deprecated  :: When2 t Declaration Definition (Maybe Bool)
  , _fullRange   :: When2 t Declaration Definition LSP.Range
  , _detail      :: When2 t Declaration Definition (Maybe Text)
  } deriving Generic

type DeclarationTag = RangeTag Declaration
type DefinitionTag  = RangeTag Definition
type ReferenceTag   = RangeTag Reference
type UnknownTag     = RangeTag Unknown

mkDeclarationTag = mkConstr (Proxy @DeclarationTag) SDeclaration
mkDefinitionTag  = mkConstr (Proxy @DefinitionTag) SDefinition
mkReferenceTag   = mkConstr (Proxy @ReferenceTag) SReference
mkUnknownTag     = mkConstr (Proxy @UnknownTag) SUnknown

instance A.ToJSON DeclarationTag where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON DefinitionTag where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON ReferenceTag where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
instance A.ToJSON UnknownTag where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts


data RangeBasedDocumentSymbol
  = RangeBasedDocumentSymbol
  { _id :: LsifId
  , _children :: Maybe [RangeBasedDocumentSymbol]
  } deriving (Generic)

instance A.ToJSON RangeBasedDocumentSymbol where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

data ToolInfo
  = ToolInfo
  { _name :: Text
  , _args :: Maybe [Text]
  } deriving (Show, Generic)

instance A.ToJSON ToolInfo where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

type AdditionalData = A.Value

data Repository
  = Repository
  { _type :: Text
  , _url :: LSP.Uri
  , _commitId :: Maybe Text
  } deriving (Eq,Ord,Show,Generic)

instance A.ToJSON Repository where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts

data ItemEdgeProperties
  = Declarations
  | Definitions
  | References
  | ReferenceResults
  | ImplementationResults
  deriving (Eq,Ord,Show,Generic,Enum)

instance A.ToJSON ItemEdgeProperties where
  toEncoding = A.genericToEncoding aesonOpts
  toJSON = A.genericToJSON aesonOpts
