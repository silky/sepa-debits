{-# LANGUAGE
  FlexibleContexts,
  FlexibleInstances,
  GADTs,
  NoImplicitPrelude,
  OverloadedStrings,
  TypeFamilies
  #-}

module Guia.DirectDebitMessageXML where

import qualified Prelude
  (zip)

import           ClassyPrelude    --      hiding (Text)
import           Control.Lens
import qualified Data.List                                                      as L
  (genericDrop)
import qualified Data.Map                                                       as M
import qualified Data.Text.Lazy                                                 as LT
  (Text)
import qualified Data.Time.Calendar                                             as T
import qualified Data.Time.Calendar.Easter                                      as T
import           Guia.BillingConcept
import           Guia.Creditor
import           Guia.Debtor
import           Guia.DirectDebit
import           Guia.SpanishIban
import qualified Text.Printf                                                    as PF
 (printf)
import           Text.XML               hiding (writeFile)
import qualified Text.XML.Light.Input                                           as LXML
import qualified Text.XML.Light.Output                                          as LXML

-- For testing only
import qualified Database.Persist.MongoDB as DB
import qualified Guia.MongoUtils as DB
import qualified Data.Time.LocalTime as T


-- Type synonims

type BankMap = M.Map Text SpanishBank


-- Recursive transformation DirectDebitSet -> Document

message :: DirectDebitSet -> BankMap -> Document                      -- *
message dds bkM = Document prologue root epilogue
  where
    prologue = Prologue [] Nothing []
    root     = Element "CstmrDrctDbtInitn" M.empty subnodes
    epilogue = []
    subnodes = grpHdr dds : pmtInf_L dds bkM

grpHdr :: DirectDebitSet -> Node                                      -- +
grpHdr dds = nodeElem "GrpHdr" subnodes
  where
    subnodes = [ msgId dds, creDtTm dds, nbOfTxs_1_6 dds
               , ctrlSum_1_7 (dds ^. debits), initgPty dds]

msgId :: DirectDebitSet -> Node                                       -- ++
msgId dds = nodeContent "MsgId" (messageId dds)

creDtTm :: DirectDebitSet -> Node                                     -- ++
creDtTm dds = nodeContent "CreDtTm" (isoDate ++ "T" ++ isoTime)
  where
    isoDate      = T.showGregorian (dds ^. creationDay)
    (isoTime, _) = break (=='.') $ show (dds ^. creationTimeOfDay)

nbOfTxs_1_6 :: DirectDebitSet -> Node                                 -- ++
nbOfTxs_1_6 dds = nodeContent "NbOfTxs" (length (dds ^. debits))

-- FIXME: sum things only once
ctrlSum_1_7 :: [DirectDebit] -> Node                                  -- ++
ctrlSum_1_7 =
  nodeContent "CtrlSum" . priceToText . sumOf (traverse.items.traverse.finalPrice)

initgPty :: DirectDebitSet -> Node                                    -- ++
initgPty dds = nodeElem "InitgPty" [nm (dds ^. creditor)]

nm :: Creditor -> Node                                                -- +++
nm c = nodeContent "Nm" (c ^. fullName)

-- | Returns one or two nodes of type "PmtInf", one for debits with new mandates and
-- another for old ones.
pmtInf_L :: DirectDebitSet -> BankMap -> [Node]                       -- *
pmtInf_L dds bkM =
  concat $ (pmtInf' True new, pmtInf' False old) ^.. both
  where
    -- Use of lenses and list comprehensions
    (new, old) = span (^. mandate.isNew) (dds ^.. debits.traverse)
    pmtInf' areNew ddL = [pmtInf areNew ddL dds bkM| not (null ddL)]

pmtInf :: Bool -> [DirectDebit] -> DirectDebitSet -> BankMap ->
          Node                                                        -- +
pmtInf areNew ddL dds bkM = nodeElem "pmtInf" subnodes
  where
    subnodes = [ pmtInfId areNew dds, pmtMtd, btchBookg, nbOfTxs_2_4 ddL
               , ctrlSum_2_5 ddL, pmtTpInf areNew, reqdColltnDt dds
               , cdtr c, cdtrAcct c, cdtrAgt c bkM, cdtrSchmeId c ]
               ++ drctDbtTxInf_L c ddL d bkM
    c        = dds ^. creditor
    d        = dds ^. creationTime

pmtInfId :: Bool -> DirectDebitSet -> Node                            -- ++
pmtInfId areNew dds = nodeContent "PmtInfId" paymentId
  where
    paymentId = prefix ++ drop 3 (messageId dds)
    prefix    = if areNew then "FST" else "REC"

pmtMtd :: Node                                                        -- ++
pmtMtd = nodeContent "PmtMtd" ("DD" :: Text)

btchBookg :: Node                                                     -- ++
btchBookg = nodeContent "BtchBookg" ("TRUE" :: Text)

nbOfTxs_2_4 :: [DirectDebit] -> Node                                  -- ++
nbOfTxs_2_4 = nodeContent "NbOfTxs" . length

ctrlSum_2_5 :: [DirectDebit] -> Node                                  -- ++
ctrlSum_2_5 =
  nodeContent "CtrlSum" . priceToText . sumOf (traverse.items.traverse.finalPrice)

pmtTpInf :: Bool -> Node                                              -- ++
pmtTpInf areNew = nodeElem "PmtTpInf" subnodes
  where
    subnodes = [svcLvl, lclInstrm, seqTp areNew]

svcLvl :: Node                                                        -- +++
svcLvl = nodeElem "SvcLvl" [cd_2_9]

cd_2_9 :: Node                                                        -- ++++
cd_2_9 = nodeContent "Cd" ("SEPA" :: Text)

lclInstrm :: Node                                                     -- +++
lclInstrm = nodeElem "LclInstrm" [cd_2_12]

cd_2_12 :: Node                                                       -- ++++
cd_2_12 = nodeContent "Cd" ("CORE" :: Text)

seqTp :: Bool -> Node                                                 -- +++
seqTp areNew =
  nodeContent "SeqTp" $ if areNew then ("FRST" :: Text) else "RCUR"

-- | Requests a payment in 7 working days for all direct debits, even if recurrent
-- mandates.
reqdColltnDt :: DirectDebitSet -> Node                                -- ++
reqdColltnDt dds =
  nodeContent "ReqdColltnDt" $ T.showGregorian (addWorkingDays 7 (dds ^. creationDay))

cdtr :: Creditor -> Node                                              -- ++
cdtr c = nodeElem "Cdtr" [nm_2_19 c]

nm_2_19 :: Creditor -> Node                                           -- +++
nm_2_19 c = nodeContent "Nm" (c ^. fullName)

cdtrAcct :: Creditor -> Node                                          -- ++
cdtrAcct c = nodeElem "CdtrAcct" [id_2_20 c]

id_2_20 :: Creditor -> Node                                           -- +++
id_2_20 c = nodeElem "Id" [iban_ c]

iban_ :: Creditor -> Node
iban_ c = nodeContent "IBAN" (c ^. creditorIban)                      -- ++++

cdtrAgt :: Creditor -> BankMap -> Node                                -- ++
cdtrAgt c bkM = nodeElem "CdtrAgt" [finInstnId c bkM]

finInstnId :: Creditor -> BankMap -> Node                             -- +++
finInstnId c bkM = nodeElem "FinInstnId" [bic_2_21 c bkM]

bic_2_21 :: Creditor -> BankMap -> Node                               -- ++++
bic_2_21 c bkM = nodeContent "BIC" bicOfc
  where
    bicOfc = case lookup (c ^. creditorIban ^. bankDigits) bkM of
      Just bk   -> take 8 (bk ^. bic) -- Office code is optional
      Nothing   -> error "bic_2_21: can't lookup SpanishBank"

cdtrSchmeId :: Creditor -> Node                                       -- ++
cdtrSchmeId c = nodeElem "CdtrSchmeId" [id_2_27 c]

id_2_27 :: Creditor -> Node                                           -- +++
id_2_27 c = nodeElem "Id" [prvtId c]

prvtId :: Creditor -> Node                                            -- ++++
prvtId c = nodeElem "PrvtId" [other c]

other :: Creditor -> Node                                             -- +++++
other c = nodeElem "Other" [id_2_27_b c, prtry]

id_2_27_b :: Creditor -> Node                                         -- ++++++
id_2_27_b c = nodeContent "Id" (c ^. sepaId)

schmeNm :: Node                                                       -- ++++++
schmeNm = nodeElem "SchmeNm" [prtry]

prtry :: Node                                                         -- +++++++
prtry = nodeContent "Prtry" ("SEPA" :: Text)

drctDbtTxInf_L :: Creditor -> [DirectDebit] -> T.ZonedTime -> BankMap ->
                  [Node]                                              -- *
drctDbtTxInf_L c ddL d bkM = map (\idd -> drctDbtTxInf idd c d bkM) indexedDdL
  where
    indexedDdL = Prelude.zip [1..] ddL

drctDbtTxInf :: (Int, DirectDebit) -> Creditor -> T.ZonedTime -> BankMap ->
                Node                                                  -- ++
drctDbtTxInf (i, dd) c d bkM = nodeElem "DrctDbtTxInf" subnodes
  where
    subnodes = [pmtId i c d, instdAmt dd, drctDbtTx (dd ^. mandate)]

pmtId :: Int -> Creditor -> T.ZonedTime -> Node                       -- +++
pmtId i c d = nodeElem "PmtId" [endToEndId i c d]

endToEndId :: Int -> Creditor -> T.ZonedTime -> Node                  -- ++++
endToEndId i c d = nodeContent "EndToEndId" endToEndId'
  where
    -- FIXME: refactor with messageId
    endToEndId' :: Text
    endToEndId' = yyyymmdd ++ hhmmss ++ messageCount_ ++ debitCount
    yyyymmdd          = pack $ filter (/= '-') $ T.showGregorian (T.localDay localTime)
    (hhmmss', _)      = break (== '.') $ show (T.localTimeOfDay localTime)
    hhmmss            = pack $ filter (/= ':') hhmmss'
    localTime         = T.zonedTimeToLocalTime d
    messageCount_     = pack $ PF.printf "%013d" (c ^. messageCount)
    debitCount        = pack $ PF.printf "%08d" i

instdAmt :: DirectDebit -> Node                                       -- +++
instdAmt dd = NodeElement $ Element "InstdAmt" (M.singleton "Ccy" "EUR") [content]
  where
    content = NodeContent $ priceToText (sumOf (items.traverse.finalPrice) dd)

drctDbtTx :: Mandate -> Node                                          -- +++
drctDbtTx m = nodeElem "DrctDbtTx" [mndtRltdInf m]

mndtRltdInf :: Mandate -> Node                                        -- ++++
mndtRltdInf m = nodeElem "MndtRltdInf" [mndtId m, dtOfSgntr m]

mndtId :: Mandate -> Node                                             -- +++++
mndtId m = nodeContent "MndtId" (m ^. mandateRef)

dtOfSgntr :: Mandate -> Node                                          -- +++++
dtOfSgntr m = nodeContent "DtOfSgntr" $ T.showGregorian (m ^. signatureDate)


-- Helper functions for nodes without attributes

nodeElem :: Name -> [Node] -> Node
nodeElem name subnodes  = NodeElement $ Element name M.empty subnodes

nodeContent :: Content c => Name -> c -> Node
nodeContent name content
  = NodeElement $ Element name M.empty [NodeContent (toContent content)]

class Show c => Content c where
  toContent :: c -> Text
  toContent = pack . show

instance Content Text where
  toContent = id

instance Content String where
  toContent = pack

instance Content Int


-- Other helper functions

messageId :: DirectDebitSet -> Text
messageId dds = "PRE" ++ yyyymmdd ++ hhmmss ++ milis ++ count
  where
    creation_         = dds ^. creationTime
    creditor_         = dds ^. creditor
    yyyymmdd          = pack $ filter (/= '-') $ T.showGregorian (T.localDay localTime)
    (hhmmss', milis') = break (== '.') $ show (T.localTimeOfDay localTime)
    hhmmss            = pack $ filter (/= ':') hhmmss'
    milis             = pack $ take 5 $ dropWhile (== '.') (milis' ++ repeat '0')
                        -- TODO: messageCount is updated elsewhere
    count             = pack $ PF.printf "%013d" (creditor_ ^. messageCount)

    -- A LocalTime contains only a Day and a TimeOfDay, so messageId generation doesn't
    -- depend on the local time zone.
    localTime =       T.zonedTimeToLocalTime creation_


-- Non-working days for banking (in Spain): all saturdays, all sundays, New Year's Day,
-- Friday before Easter, Monday after Easter, May Day, 25 and 26 December
-- (http://www.lavanguardia.com/economia/20130704/54377221106/cuanto-tarda-en-hacerse-efectiva-una-transferencia-bancaria.html)
-- Very inefficient, but simple, works for i small.
addWorkingDays :: Integer -> T.Day -> T.Day
addWorkingDays i d =
  assert (i >= 0)
  $ case nextWorkDays of { n : _ -> n; [] -> error "addWorkingDays" }
  where
    nextWorkDays    = L.genericDrop (if (isWorkDay d) then i else i - 1) allWorkDays
    allWorkDays     = filter isWorkDay (allDaysSince d)
    isWorkDay    d_ = not $ any ($ d_) [isWeekend, isFest 1 1, isFest 5 1, isFest 12 25
                                 , isFest 12 26, isEasterFOrM]
    allDaysSince d_ = d_ : map (T.addDays 1) (allDaysSince d_)
                      -- sundayAfter is "strictly" after, so we can only substract
    isWeekend    d_ = any (\f -> f (T.sundayAfter d_) == d_) [T.addDays (-7), T.addDays (-1)]
    isFest mm dd d_ = d_ == T.fromGregorian (yearOf d_) mm dd
                      -- gregorianEaster gives Easter day in year of d (can be before d)
    isEasterFOrM d_ = any (\f -> f (T.gregorianEaster (yearOf d_)) == d_) [T.addDays (-2), T.addDays 1]
    yearOf       d_ = let (yy, _, _) = T.toGregorian d_ in yy

    -- -- Infinite lists of next (strictly after 'd') non-working days
    -- sundays         = T.sundayAfter d : map (T.addDays 7) sundays
    -- saturdays       = map (T.addDays (-1)) sundays -- Yes! it's 'sundays'!
    -- newYears        = yearlyOf 1  1
    -- mayDays         = yearlyOf 5  1
    -- christmas       = yearlyOf 12 25
    -- stStevens       = yearlyOf 12 26
    -- fridaysBEaster  = dropWhile (<= d) $ map (T.addDays (-2) . T.gregorianEaster) [yy..]
    -- mondaysAEaster  = dropWhile (<= d) $ map (T.addDays 1 .    T.gregorianEaster) [yy..]
    -- yearlyOf  mm dd = dropWhile (<= d) (yearlyOf' mm dd)
    -- yearlyOf' mm dd = T.fromGregorian yy mm dd : map (T.addGregorianYearsClip 1) (yearlyOf' mm dd)
    -- (yy, _, _)      = T.toGregorian d
    -- l = L.transpose [ sundays, saturdays, newYears, mayDays, christmas, stStevens, fridaysBEaster, mondaysAEaster]


-- Rendering and writing of messages

renderMessage :: DirectDebitSet -> BankMap -> LT.Text
renderMessage dds bkM = renderText settings (message dds bkM)
  where
    settings = def { rsPretty = False }

-- | Write direct debits instructions message to XML file, with a decent pretty-printer
-- (the one coming with Text.XML puts significant whitespace in content nodes).
writeMessageToFile :: DirectDebitSet -> BankMap -> IO ()
writeMessageToFile dds bkM = do
  -- TODO: handle possible error
  let (Just xmlParsedLight) = LXML.parseXMLDoc (renderMessage dds bkM)
  writeFile "Test.xml" (LXML.ppTopElement xmlParsedLight)


-- Test data

dds_ :: IO DirectDebitSet
dds_ = do
  (Just ddsE) <- DB.runDb $ DB.selectFirst ([] :: [DB.Filter DirectDebitSet]) []
  return $ DB.entityVal ddsE

insertDDS :: IO ()
insertDDS = DB.runDb $ do
  now <- liftIO T.getZonedTime
  liftIO $ putStrLn "Get creditor"
  (Just cE)  <- DB.selectFirst ([] :: [DB.Filter Creditor])       []
  liftIO $ putStrLn "Get debtor"
  dEL  <- DB.selectList ([] :: [DB.Filter Debtor])         []
  liftIO $ putStrLn "Get billing concept"
  bcEL       <- DB.selectList  ([] :: [DB.Filter BillingConcept]) []
  let c = DB.entityVal cE
      (d1 : d2 : _) = map DB.entityVal dEL
      (m1 : _) = d1 ^.. mandates.traversed
      (m2 : _) = d2 ^.. mandates.traversed
      (bc1 : bc2 : _) = map DB.entityVal bcEL
      dd1 = mkDirectDebit (d1 ^. firstName) (d1 ^. lastName) m1 [bc1, bc2] ""
      dd2 = mkDirectDebit (d2 ^. firstName) (d2 ^. lastName) m2 [bc1] ""
      dds = mkDirectDebitSet "New DdSet" now c [dd1, dd2]
  liftIO $ putStrLn "Insert"
  DB.deleteWhere ([] :: [DB.Filter DirectDebitSet])
  DB.insert_ dds
  return ()
