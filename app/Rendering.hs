{-# LANGUAGE NoMonomorphismRestriction, FlexibleContexts, TypeFamilies, PartialTypeSignatures, ScopedTypeVariables #-}

module Rendering (
  renderDrawing,
  customLayoutParams,
  renderIngSyntaxGraph
) where

import Diagrams.Prelude hiding ((#), (&))
import Diagrams.TwoD.GraphViz(mkGraph, getGraph, layoutGraph')

import qualified Data.GraphViz as GV
import qualified Data.GraphViz.Attributes.Complete as GVA
import qualified Data.Map as Map

import Data.Function(on)
import qualified Data.Graph.Inductive as ING
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.List(minimumBy)
import Data.Maybe(fromMaybe)
import Data.Typeable(Typeable)

--import qualified Data.GraphViz.Types
--import Data.GraphViz.Commands
--import qualified Debug.Trace
--import Data.Word(Word16)

import Icons(colorScheme, iconToDiagram, defaultLineWidth, ColorStyle(..), getPortAngles)
import TranslateCore(nodeToIcon)
import Types(Edge(..), Icon, EdgeOption(..), Drawing(..), EdgeEnd(..),
  NameAndPort(..), SpecialQDiagram, SpecialBackend, SpecialNum, NodeName(..), Port(..),
  SgNamedNode)
import Util(fromMaybeError, mapNodeInNamedNode)

-- If the inferred types for these functions becomes unweildy,
-- try using PartialTypeSignitures.

-- CONSTANT
graphvizScaleFactor :: (Fractional a) => a

-- For Neato
graphvizScaleFactor = 0.12

-- For Fdp
--scaleFactor = 0.09

--scaleFactor = 0.04

drawingToGraphvizScaleFactor :: Fractional a => a
-- For Neato, ScaleOverlaps
--drawingToGraphvizScaleFactor = 0.08

-- For Neato, PrismOverlap
drawingToGraphvizScaleFactor = 0.15

-- TODO Refactor with syntaxGraphToFglGraph in TranslateCore
-- TODO Make this work with nested icons now that names are not qualified.
drawingToIconGraph :: Drawing -> Gr (NodeName, Icon) Edge
drawingToIconGraph (Drawing nodes edges) =
  mkGraph nodes labeledEdges where
    labeledEdges = fmap makeLabeledEdge edges
    makeLabeledEdge e@(Edge _ _ (NameAndPort n1 _, NameAndPort n2 _)) =
      ((n1, lookupInNodes n1), (n2, lookupInNodes n2), e) where
        lookupInNodes name = fromMaybeError errorString (lookup name nodes) where
          errorString =
            "syntaxGraphToFglGraph edge connects to non-existent node. Node NodeName ="
            ++ show name ++ " Edge=" ++ show e


-- | Custom arrow tail for the arg1 result circle.
-- The ArrowHT type does not seem to be documented.
arg1ResT :: (RealFloat n) => ArrowHT n
arg1ResT len _ = (alignR $ circle (len / 2), mempty)

-- | Arrow head version of arg1ResT
arg1ResH :: (RealFloat n) => ArrowHT n
arg1ResH len _ = (alignL $ circle (len / 2), mempty)

bezierShaft :: (V t ~ V2, TrailLike t) => Angle (N t) -> Angle (N t) -> t
bezierShaft angle1 angle2 = fromSegments [bezier3 c1 c2 x] where
  scaleFactor = 0.5
  x = r2 (1,0)
  c1 = rotate angle1 (scale scaleFactor unitX)
  c2 = rotate angle2 (scale scaleFactor unitX) ^+^ x

getArrowOpts :: (RealFloat n, Typeable n) => (EdgeEnd, EdgeEnd) -> [EdgeOption] -> (Angle n, Angle n) -> NameAndPort -> ArrowOpts n
getArrowOpts (t, h) _ (fromAngle, toAngle) (NameAndPort (NodeName nodeNum) mPort)= arrowOptions
  where
    --shaftColor = if EdgeInPattern `elem` opts then patternC colorScheme else hashedColor
    shaftColor = hashedColor

    edgeColors = edgeListC colorScheme
    numEdgeColors = length edgeColors
    hashedColor = edgeColors !! namePortHash
    namePortHash = mod (portNum + (503 * nodeNum)) numEdgeColors
    Port portNum = fromMaybe (Port 0) mPort

    ap1ArgTexture = solid (backgroundC colorScheme)
    ap1ArgStyle = lwG defaultLineWidth . lc (apply1C colorScheme)
    ap1ResultTexture = solid (apply1C colorScheme)

    lookupTail EndNone = id
    lookupTail EndAp1Arg = (arrowTail .~ dart')
      . (tailTexture .~ ap1ArgTexture) . (tailStyle %~  ap1ArgStyle)
    lookupTail EndAp1Result = (arrowTail .~ arg1ResT) . (tailTexture .~ ap1ResultTexture)

    lookupHead EndNone = id
    lookupHead EndAp1Arg = (arrowHead .~ dart)
      . (headTexture .~ ap1ArgTexture) . (headStyle %~ ap1ArgStyle)
    lookupHead EndAp1Result = (arrowHead .~ arg1ResH) . (headTexture .~ ap1ResultTexture)

    arrowOptions =
      arrowHead .~ noHead $
      arrowTail .~ noTail $
      arrowShaft .~ bezierShaft fromAngle toAngle $
      lengths .~ global 0.75 $
      shaftStyle %~ (lwG (2 * defaultLineWidth) . lc shaftColor) $
      lookupHead h $ lookupTail t with

-- | Given an Edge, return a transformation on Diagrams that will draw a line.
connectMaybePorts :: SpecialBackend b n =>
  (Angle n, Angle n)-> Edge -> SpecialQDiagram b n -> SpecialQDiagram b n
connectMaybePorts portAngles (Edge opts ends (fromNamePort@(NameAndPort name0 mPort1), NameAndPort name1 mPort2)) =
  connectFunc (getArrowOpts ends opts portAngles fromNamePort) qPort0 qPort1 where
  (connectFunc, qPort0, qPort1) = case (mPort1, mPort2) of
    (Just port0, Just port1) -> (connect', name0 .> port0, name1 .> port1)
    (Nothing, Just port1) -> (connectOutside', toName name0, name1 .> port1)
    (Just port0, Nothing) -> (connectOutside', name0 .> port0, toName name1)
    (_, _) -> (connectOutside', toName name0, toName name1)

-- START addEdges --
nameAndPortToName :: NameAndPort -> Name
nameAndPortToName (NameAndPort name mPort) = case mPort of
  Nothing -> toName name
  Just port -> name .> port

findPortAngles :: SpecialNum n => (NodeName, Icon) -> NameAndPort -> [Angle n]
findPortAngles (nodeName, nodeIcon) (NameAndPort diaName mPort) = case mPort of
  Nothing -> []
  Just port -> foundAngles where
    mName = if nodeName == diaName then Nothing else Just diaName
    foundAngles = getPortAngles nodeIcon port mName

-- TODO Clean up the Angle arithmatic
pickClosestAngle :: SpecialNum n => (Bool, Angle n) -> Angle n -> Angle n -> Angle n -> [Angle n] -> Angle n
pickClosestAngle (nodeFlip, nodeAngle) emptyCase target shaftAngle angles = case angles of
  [] -> emptyCase
  _ -> (-) <$>
    fst (minimumBy (compare `on` snd) $ fmap angleDiff adjustedAngles)
    <*>
    shaftAngle
    where
      adjustedAngles = fmap adjustAngle angles
      angleDiff angle = (angle, angleBetween (angleV target) (angleV angle))

      adjustAngle angle = if nodeFlip then
        signedAngleBetween (rotate nodeAngle $ reflectX (angleV angle)) unitX
        else
        (+) <$> angle <*> nodeAngle

-- TODO Refactor with pickClosestAngle
smallestAngleDiff :: SpecialNum n => (Bool, Angle n) -> Angle n -> [Angle n] -> n
smallestAngleDiff (nodeFlip, nodeAngle) target angles = case angles of
  [] -> 0
  _ -> minimum $ fmap angleDiff adjustedAngles
    where
      adjustedAngles = fmap adjustAngle angles
      angleDiff angle = angleBetween (angleV target) (angleV angle) ^. rad

      adjustAngle angle = if nodeFlip then
        signedAngleBetween (rotate nodeAngle $ reflectX (angleV angle)) unitX
        else
        (+) <$> angle <*> nodeAngle


lookupNodeAngle ::  Show n => [((NodeName, Icon), (Bool, Angle n))] -> (NodeName, Icon) -> (Bool, Angle n)
lookupNodeAngle rotationMap key =
  fromMaybeError ("nodeVector: key not in rotaionMap. key = " ++ show key ++ "\n\n rotationMap = " ++ show rotationMap)
  $ lookup key rotationMap

makeEdge :: (SpecialBackend b n, ING.Graph gr) =>
  gr (NodeName, Icon) Edge -> SpecialQDiagram b n -> [((NodeName, Icon), (Bool, Angle n))] ->
  ING.LEdge Edge -> SpecialQDiagram b n -> SpecialQDiagram b n
makeEdge graph dia rotationMap (node0, node1, edge@(Edge _ _ (namePort0, namePort1))) =
  connectMaybePorts portAngles edge
  where
    node0label = fromMaybeError ("makeEdge: node0 is not in graph. node0: " ++ show node0) $
      ING.lab graph node0
    node1label = fromMaybeError ("makeEdge: node1 is not in graph. node1: " ++ show node1) $
      ING.lab graph node1

    node0Angle = lookupNodeAngle rotationMap node0label
    node1Angle = lookupNodeAngle rotationMap node1label

    diaNodeNamePointMap = names dia
    port0Point = getPortPoint $ nameAndPortToName namePort0
    port1Point = getPortPoint $ nameAndPortToName namePort1
    shaftVector = port1Point .-. port0Point
    shaftAngle = signedAngleBetween shaftVector unitX

    icon0PortAngle = pickClosestAngle node0Angle mempty shaftAngle shaftAngle $ findPortAngles node0label namePort0

    shaftAnglePlusOneHalf = (+) <$> shaftAngle <*> (1/2 @@ turn)
    icon1PortAngle = pickClosestAngle node1Angle (1/2 @@ turn) shaftAnglePlusOneHalf shaftAngle $ findPortAngles node1label namePort1

    getPortPoint n = head $ fromMaybeError
      ("makeEdge: port not found. Port: " ++ show n ++ ". Valid ports: " ++ show diaNodeNamePointMap)
      (lookup n diaNodeNamePointMap)
    
    portAngles = (icon0PortAngle, icon1PortAngle)

-- | addEdges draws the edges underneath the nodes.
addEdges :: (SpecialBackend b n, ING.Graph gr) =>
  gr (NodeName, Icon) Edge -> (SpecialQDiagram b n, [((NodeName, Icon), (Bool, Angle n))]) -> SpecialQDiagram b n
addEdges graph (dia, rotationMap) = dia <> applyAll connections dia
  where
    connections = makeEdge graph dia rotationMap <$> ING.labEdges graph

--printSelf :: (Show a) => a -> a
--printSelf a = Debug.Trace.trace (show a ++ "/n") a

-- BEGIN rotateNodes --

-- TODO May want to use a power other than 2 for the edgeAngleDiffs
scoreAngle :: SpecialNum n =>
  Point V2 n
  -> [(Point V2 n, [Angle n])]
  -> Bool
  -> Angle n
  -> n
scoreAngle iconPosition edges reflected angle = sum $ (^(2 :: Int)) <$> fmap edgeAngleDiff edges where
  edgeAngleDiff (otherNodePosition, portAngles) = angleDiff where
    shaftVector = otherNodePosition .-. iconPosition
    shaftAngle = signedAngleBetween shaftVector unitX
    angleDiff = smallestAngleDiff (reflected, angle) shaftAngle portAngles

bestAngleForIcon :: (SpecialNum n, ING.Graph gr) =>
  Map.Map (NodeName, Icon) (Point V2 n)
  -> gr (NodeName, Icon) Edge
  -> (NodeName, Icon)
  -> Bool
  -> (Angle n, n)
bestAngleForIcon positionMap graph key@(NodeName nodeId, _) reflected =
  minimumBy (compare `on` snd) $ (\angle -> (angle, scoreAngle iconPosition edges reflected angle)) <$> fmap (@@ turn) possibleAngles
  where
    possibleAngles = [0,(1/24)..1]
    -- possibleAngles = [0, 1/2] -- (uncomment this line and comment out the line above to disable rotation)
    iconPosition = positionMap Map.! key
    edges = getPositionAndAngles <$> fmap getSucEdge (ING.lsuc graph nodeId) <> fmap getPreEdge (ING.lpre graph nodeId)
  
    getPositionAndAngles (node, nameAndPort) = (positionMap Map.! nodeLabel, portAngles) where
      nodeLabel = fromMaybeError "getPositionAndAngles: node not found" $ ING.lab graph node
      portAngles = findPortAngles key nameAndPort  

  -- Edge points from id to otherNode
    getSucEdge (otherNode, edge) = (otherNode, nameAndPort) where
      (nameAndPort, _) = edgeConnection edge

  -- Edge points from otherNode to id
    getPreEdge (otherNode, edge) = (otherNode, nameAndPort) where
      (_, nameAndPort) = edgeConnection edge

findIconRotation :: (SpecialNum n, ING.Graph gr) =>
  Map.Map (NodeName, Icon) (Point V2 n)
  -> gr (NodeName, Icon) Edge
  -> (NodeName, Icon)
  -> ((NodeName, Icon), (Bool, Angle n))
findIconRotation positionMap graph key = (key, (reflected, angle)) where
  -- Smaller scores are better
  (reflectedAngle, reflectedScore) = bestAngleForIcon positionMap graph key True
  (nonReflectedAngle, nonReflectedScore) = bestAngleForIcon positionMap graph key False
  reflected = reflectedScore < nonReflectedScore
  angle = if reflected then reflectedAngle else nonReflectedAngle

rotateNodes :: (SpecialNum n, ING.Graph gr) =>
  Map.Map (NodeName, Icon) (Point V2 n)
  -> gr (NodeName, Icon) Edge
  -> [((NodeName, Icon), (Bool, Angle n))]
rotateNodes positionMap graph = findIconRotation positionMap graph <$> Map.keys positionMap

-- END rotateNodes --

type LayoutResult a b = Gr (GV.AttributeNode (NodeName, b)) (GV.AttributeNode a)

placeNodes :: forall a b gr. (SpecialBackend b Double, ING.Graph gr) =>
   LayoutResult a Icon
   -> gr (NodeName, Icon) Edge
   -> (SpecialQDiagram b Double, [((NodeName, Icon), (Bool, Angle Double))])
placeNodes layoutResult graph = (mconcat placedNodes, rotationMap)
  where
    positionMap = fst $ getGraph layoutResult
    rotationMap = rotateNodes positionMap graph

    placedNodes = fmap placeNode rotationMap

    -- todo: Not sure if the diagrams should already be centered at this point.
    placeNode (key@(name, icon), (reflected, angle)) = place transformedDia diaPosition where
      origDia = iconToDiagram icon name 0 reflected angle
      transformedDia = centerXY $ rotate angle $ (if reflected then reflectX else id) origDia
      diaPosition = graphvizScaleFactor *^ (positionMap Map.! key)

customLayoutParams :: GV.GraphvizParams n v e () v
customLayoutParams = GV.defaultParams{
  GV.globalAttributes = [
    GV.NodeAttrs [GVA.Shape GVA.BoxShape]
    --GV.NodeAttrs [GVA.Shape GVA.Circle]
    , GV.GraphAttrs
      [
      --GVA.Overlap GVA.KeepOverlaps,
      --GVA.Overlap GVA.ScaleOverlaps,
      GVA.Overlap $ GVA.PrismOverlap (Just 5000),
      GVA.Splines GVA.LineEdges,
      GVA.OverlapScaling 8,
      --GVA.OverlapScaling 4,
      GVA.OverlapShrink True
      ]
    ],
  GV.fmtEdge = const [GV.arrowTo GV.noArrow]
  }

doGraphLayout :: forall b.
  SpecialBackend b Double =>
  Gr (NodeName, Icon) Edge
  -> IO (SpecialQDiagram b Double)
doGraphLayout graph = do
  layoutResult <- layoutGraph' layoutParams GVA.Neato graph
  --  layoutResult <- layoutGraph' layoutParams GVA.Fdp graph
  pure $ addEdges graph $ placeNodes layoutResult graph
  where
    layoutParams :: GV.GraphvizParams Int (NodeName,Icon) e () (NodeName,Icon)
    --layoutParams :: GV.GraphvizParams Int l el Int l
    layoutParams = customLayoutParams{
      GV.fmtNode = nodeAttribute
      }
    nodeAttribute :: (Int, (NodeName, Icon)) -> [GV.Attribute]
    nodeAttribute (_, (_, nodeIcon)) =
      -- GVA.Width and GVA.Height have a minimum of 0.01
      --[GVA.Width diaWidth, GVA.Height diaHeight]
      [GVA.Width circleDiameter, GVA.Height circleDiameter]
      where
        -- This type annotation (:: SpecialQDiagram b n) requires Scoped Typed Variables, which only works if the function's
        -- type signiture has "forall b e."
        dia = iconToDiagram nodeIcon (NodeName (-1)) 0 False mempty :: SpecialQDiagram b Double

        diaWidth = drawingToGraphvizScaleFactor * width dia
        diaHeight = drawingToGraphvizScaleFactor * height dia
        circleDiameter' = max diaWidth diaHeight
        circleDiameter = if circleDiameter' <= 0.01 then error ("circleDiameter too small: " ++ show circleDiameter') else circleDiameter'

-- | Given a Drawing, produce a Diagram complete with rotated/flipped icons and
-- lines connecting ports and icons. IO is needed for the GraphViz layout.
renderDrawing ::
  SpecialBackend b Double =>
  Drawing -> IO (SpecialQDiagram b Double)
renderDrawing = renderIconGraph . drawingToIconGraph

renderIngSyntaxGraph ::
  SpecialBackend b Double =>
  Gr SgNamedNode Edge -> IO (SpecialQDiagram b Double)
renderIngSyntaxGraph = renderIconGraph . ING.nmap (mapNodeInNamedNode nodeToIcon)

renderIconGraph :: SpecialBackend b Double => Gr (NodeName, Icon) Edge -> IO (SpecialQDiagram b Double)
renderIconGraph = doGraphLayout
