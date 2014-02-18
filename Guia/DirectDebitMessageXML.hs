{-# LANGUAGE
  FlexibleInstances,
  GADTs,
  NoImplicitPrelude,
  OverloadedStrings,
  TypeFamilies
  #-}

module Guia.DirectDebitMessageXML
       ( writeMessageToFile,
         renderMessage,
       ) where

import qualified Prelude
  (zip)

import           ClassyPrelude
import qualified Codec.Text.IConv                                               as IC
import           Control.Lens
import qualified Data.List                                                      as L
  (genericDrop)
import qualified Data.Map                                                       as M
import qualified Data.Text.Lazy                                                 as LT
  (Text)
import qualified Data.Text.Lazy.Encoding                                        as LT
import qualified Data.Time.Calendar                                             as T
import qualified Data.Time.Calendar.Easter                                      as T
import qualified Data.Time.LocalTime                                            as T
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


-- Type synonims

type BankMap = M.Map Text SpanishBank


-- Recursive transformation DirectDebitSet -> Document

message :: DirectDebitSet -> BankMap -> Document                      -- *
message dds bkM = Document prologue root epilogue
  where
    prologue   = Prologue [creation] Nothing []
    root       = Element "Document" (M.fromList attributes) subnodes
    epilogue   = []
    subnodes   = [cstmrDrctDbtInitn dds bkM]
    attributes =  [ ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance")
                  , ("xmlns", "urn:iso:std:iso:20022:tech:xsd:pain.008.001.02") ]
    creation   = MiscComment "Generated by GuiaDirectDebits"

cstmrDrctDbtInitn :: DirectDebitSet -> BankMap -> Node                -- *
cstmrDrctDbtInitn dds bkM = nodeElem "CstmrDrctDbtInitn" subnodes
  where
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
initgPty dds = nodeElem "InitgPty" subnodes
  where
    -- Id of the initiating party needed, even if optional in SEPA specs.
    subnodes = [nm (dds ^. creditor.fullName), id_cred_init (dds ^. creditor)]

nm :: Text -> Node                                                    -- +++
nm = nodeContent "Nm"

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
pmtInf areNew ddL dds bkM = nodeElem "PmtInf" subnodes
  where
    subnodes = [ pmtInfId areNew dds, pmtMtd, {- btchBookg, -}nbOfTxs_2_4 ddL
               , ctrlSum_2_5 ddL, pmtTpInf areNew, reqdColltnDt areNew dds
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

-- "BtchBookg" is optional and seems to cause trouble
-- btchBookg :: Node                                                     -- ++
-- btchBookg = nodeContent "BtchBookg" ("true" :: Text)

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
svcLvl = nodeElem "SvcLvl" [cd "SEPA"]

cd :: Text -> Node                                                        -- ++++
cd = nodeContent "Cd"

lclInstrm :: Node                                                     -- +++
lclInstrm = nodeElem "LclInstrm" [cd "CORE"]

seqTp :: Bool -> Node                                                 -- +++
seqTp areNew =
  nodeContent "SeqTp" $ if areNew then ("FRST" :: Text) else "RCUR"

reqdColltnDt :: Bool -> DirectDebitSet -> Node                        -- ++
reqdColltnDt areNew dds = nodeContent "ReqdColltnDt" reqDay
  where
    reqDay = T.showGregorian (addWorkingDays n (dds ^. creationDay))
    n      = if areNew then 7 else 4

cdtr :: Creditor -> Node                                              -- ++
cdtr c = nodeElem "Cdtr" [nm_2_19 c]

nm_2_19 :: Creditor -> Node                                           -- +++
nm_2_19 c = nodeContent "Nm" (c ^. fullName)

cdtrAcct :: Creditor -> Node                                          -- ++
cdtrAcct c = nodeElem "CdtrAcct" [id_iban (c ^. creditorIban)]

-- This "id" label is easy to refactor, but not the others, as have different sub-element
-- structure.
id_iban :: IBAN -> Node                                               -- +++
id_iban i = nodeElem "Id" [iban_ i]

iban_ :: IBAN -> Node
iban_ = nodeContent "IBAN"

cdtrAgt :: Creditor -> BankMap -> Node                                -- ++
cdtrAgt c bkM = nodeElem "CdtrAgt" [finInstnId (c ^. creditorIban) bkM]

finInstnId :: IBAN -> BankMap -> Node                                 -- +++
finInstnId i bkM = nodeElem "FinInstnId" [bic_ i bkM]

bic_ :: IBAN -> BankMap -> Node                                       -- ++++
bic_ i bkM = nodeContent "BIC" bicOfc
  where
    bicOfc = case lookup (i ^. bankDigits) bkM of
      Just bk   -> take 8 (bk ^. bic) -- Office code is optional
      Nothing   -> error "bic_: can't lookup SpanishBank"

cdtrSchmeId :: Creditor -> Node                                       -- ++
cdtrSchmeId c = nodeElem "CdtrSchmeId" [id_cred_init c]

-- Identifies both the creditor and the initiating party
id_cred_init :: Creditor -> Node                                           -- +++
id_cred_init c = nodeElem "Id" [prvtId c]

prvtId :: Creditor -> Node                                            -- ++++
prvtId c = nodeElem "PrvtId" [othr c]

othr :: Creditor -> Node                                              -- +++++
othr c = nodeElem "Othr" [id_cred_init_b c, schmeNm]

id_cred_init_b :: Creditor -> Node                                         -- ++++++
id_cred_init_b c = nodeContent "Id" (c ^. sepaId)

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
    subnodes = [ pmtId i c d, instdAmt dd, drctDbtTx (dd ^. mandate)
               , dbtrAgt (dd ^. mandate) bkM, dbtr dd, dbtrAcct dd
               , rmtInf dd c ]

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

-- Back link to finInstnId
dbtrAgt :: Mandate -> BankMap -> Node                                 -- +++
dbtrAgt m bkM = nodeElem "DbtrAgt" [finInstnId (m ^. iban) bkM]

-- Back link to nm
dbtr :: DirectDebit -> Node                                           -- +++
dbtr dd = nodeElem "Dbtr" [nm name]
  where
    name = (dd ^. debtorLastName) ++ ", " ++ (dd ^. debtorFirstName)

-- Back link to id_iban
dbtrAcct :: DirectDebit -> Node                                       -- +++
dbtrAcct dd = nodeElem "DbtrAcct" [id_iban (dd ^. mandate.iban)]

rmtInf :: DirectDebit -> Creditor -> Node                             -- +++
rmtInf dd c = nodeElem "RmtInf" [ustrd dd c]

-- SEPA constraint (2.89): 1 <= length <= 140
ustrd :: DirectDebit -> Creditor -> Node                              -- ++++
ustrd dd c = nodeContent "Ustrd" itemsInfo
  where
    itemsInfo            = (c ^. activity) ++ ": " ++ itemsInfo' ++ closing
    closing              = if null more then "" else ", etc."
    (itemsInfo', more)   = splitAt 130 $ intercalate ", " groupedNames
    groupedNames         = map addCount $ groupBy shortNames sortedNames
    sortedNames          = sortBy (comparing (^. shortName)) (dd ^.. items.traverse)
    shortNames bc1 bc2   = (bc1 ^. shortName) == (bc2 ^. shortName)
    addCount []          = ""     -- Should not happen
    addCount (bc : bcs)  = let name = bc ^. shortName in
                           if null bcs then name
                           else name ++ " (x" ++ (pack . show) (length bcs + 1) ++ ")"


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
    nextWorkDays    = L.genericDrop (if isWorkDay d then i else i - 1) allWorkDays
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

-- | Write direct debits instructions message to XML file, doing some magic to combine 2
-- pretty-printers from different Haskell libraries:
--
--   - the one coming with Text.XML puts significant whitespace in content nodes
--   - the on in Text.XML.Light removes comments and other nasty things
writeMessageToFile :: DirectDebitSet -> BankMap -> IO ()
writeMessageToFile dds bkM = do
  let xmlLines = lines $ renderText (def { rsPretty = True }) (message dds bkM)
      xmlTagAndComment = take 2 xmlLines
      xmlElementL = drop 1 $ LXML.parseXML $ renderText def (message dds bkM)
      xmlPP  = pack (concatMap LXML.ppContent xmlElementL)
      xmlPP' = unlines xmlTagAndComment ++ xmlPP ++ "\n"
      xmlBS  = LT.encodeUtf8 xmlPP'
  -- TODO: look at text-icu library normalization mode for transliteration and drop
  -- dependency on iconv.
  writeFile "Test.xml" $ IC.convertFuzzy IC.Transliterate "UTF-8" "ASCII" xmlBS
